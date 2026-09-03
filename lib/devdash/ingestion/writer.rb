# frozen_string_literal: true

require "digest"
require_relative "../transports/errors"

module Devdash
  module Ingestion
    class StaleCursorError < Devdash::Error; end

    class Writer
      def initialize(registry: Devdash::Normalizers::Registry)
        @registry = registry
      end

      def call(batch)
        run = Models::CollectorRun.create!(
          source: batch.source, scope_key: batch.scope_key, status: "running",
          started_at: Time.now.utc, cursor_before: batch.cursor_before,
          cursor_after: batch.cursor_after, page_count: batch.page_count,
          retry_count: batch.retry_count
        )

        record_count = 0
        begin
          ActiveRecord::Base.transaction do
            verify_cursor!(batch)
            batch.observations.each do |observation|
              source_record, created = find_or_create_source_record!(run, batch, observation)
              normalize!(source_record) if created || normalizer_stale?(source_record, batch, observation)
              record_count += 1 if created
            end
            batch.coverages.each { |coverage| run.coverages.create!(coverage_attributes(coverage, batch)) }
            upsert_cursor!(batch)
          end

          run.update!(status: "succeeded", finished_at: Time.now.utc, record_count: record_count)
          run
        rescue StandardError => error
          run.update!(
            status: "failed", finished_at: Time.now.utc,
            error_class: error.class.name, error_message: sanitize(error.message)
          )
          raise
        end
      end

      def record_failure(source:, scope_key:, cursor_before:, error:, started_at: Time.now.utc,
        cursor_after: nil, page_count: 0, retry_count: 0)
        Models::CollectorRun.create!(
          source: source, scope_key: scope_key, status: "failed",
          started_at: started_at, finished_at: Time.now.utc,
          cursor_before: cursor_before, cursor_after: cursor_after,
          page_count: page_count, retry_count: retry_count,
          error_class: error.class.name, error_message: sanitize(error.message)
        )
      end

      private

      def verify_cursor!(batch)
        cursor = Models::SyncCursor.find_by(source: batch.source, scope_key: batch.scope_key, cursor_type: batch.cursor_type)
        actual = cursor&.cursor_value
        return if actual == batch.cursor_before

        raise StaleCursorError, "cursor changed for #{batch.source}/#{batch.scope_key}"
      end

      def find_or_create_source_record!(run, batch, observation)
        payload_json = CanonicalJson.dump(observation.payload)
        payload_hash = Digest::SHA256.hexdigest(payload_json)
        identity = {
          source: batch.source, scope_key: batch.scope_key,
          entity_type: observation.entity_type, external_id: observation.external_id,
          payload_hash: payload_hash
        }
        attributes = identity.merge(
          collector_run: run, source_updated_at: observation.source_updated_at,
          observed_at: observation.observed_at, api_version: observation.api_version,
          query_fingerprint: observation.query_fingerprint,
          payload_json: payload_json
        )
        record = Models::SourceRecord.create_or_find_by!(identity) do |candidate|
          candidate.assign_attributes(attributes)
        end
        [record, record.id_previously_changed?]
      end

      def normalizer_stale?(record, batch, observation)
        @registry.fetch(source: batch.source, entity_type: observation.entity_type).version != record.normalizer_version
      end

      def normalize!(record)
        normalizer = @registry.fetch(source: record.source, entity_type: record.entity_type)
        normalizer.call(record)
        record.update!(normalizer_version: normalizer.version)
      end

      def upsert_cursor!(batch)
        identity = { source: batch.source, scope_key: batch.scope_key, cursor_type: batch.cursor_type }
        cursor = Models::SyncCursor.find_by(identity)
        if cursor
          updated = Models::SyncCursor.where(id: cursor.id, cursor_value: batch.cursor_before).update_all(
            cursor_value: batch.cursor_after, last_succeeded_at: Time.now.utc, updated_at: Time.now.utc
          )
          raise_stale_cursor!(batch) unless updated == 1
        else
          Models::SyncCursor.create!(identity.merge(
            cursor_value: batch.cursor_after, last_succeeded_at: Time.now.utc
          ))
        end
      rescue ActiveRecord::RecordNotUnique
        raise_stale_cursor!(batch)
      end

      def coverage_attributes(coverage, batch)
        attributes = coverage.to_h
        attributes[:scope_type] = "configured" unless attributes.key?(:scope_type) || attributes.key?("scope_type")
        attributes[:scope_key] = batch.scope_key unless attributes.key?(:scope_key) || attributes.key?("scope_key")
        attributes
      end

      def raise_stale_cursor!(batch)
        raise StaleCursorError, "cursor changed for #{batch.source}/#{batch.scope_key}"
      end

      def sanitize(message)
        Devdash::Transports::Sanitizer.sanitize(message)
      end
    end
  end
end
