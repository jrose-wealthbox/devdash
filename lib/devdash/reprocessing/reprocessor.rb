# frozen_string_literal: true

require_relative "../models/normalization_run"
require_relative "../transports/errors"
require_relative "derived_rebuilder"

module Devdash
  module Reprocessing
    class Reprocessor
      def initialize(registry:, derived_rebuilder: DerivedRebuilder.new)
        @registry = registry
        @derived_rebuilder = derived_rebuilder
      end

      def call
        entries = @registry.each.to_a
        groups = entries.group_by { |(_key, normalizer)| normalizer.object_id }
        run_ids = []
        runs = groups.values.map do |group|
          (source, entity_type), normalizer = group.first
          run = Models::NormalizationRun.create!(
            normalizer_key: "#{source}:#{entity_type}", normalizer_version: normalizer.version,
            status: "running", started_at: Time.now.utc
          )
          run_ids << run.id
          run
        end

        ActiveRecord::Base.transaction do
          runs.each_with_index do |run, index|
            group = groups.values[index]
            normalizer = group.first.last
            normalizer.reset! if normalizer.respond_to?(:reset!)
            records = ordered_records(group)
            records.each do |record|
              normalizer.call(record)
              record.update!(normalizer_version: normalizer.version)
            end
            run.update!(input_count: records.length, output_count: records.length, status: "succeeded", finished_at: Time.now.utc)
          end
          @derived_rebuilder.call
        end
        runs
      rescue StandardError => error
        Models::NormalizationRun.where(id: run_ids).update_all(
          status: "failed", finished_at: Time.now.utc, error_class: error.class.name,
          error_message: Transports::Sanitizer.sanitize(error.message.to_s)[0, 1_000]
        ) unless run_ids.empty?
        raise
      end

      private

      def ordered_records(group)
        entity_order = group.each_with_index.to_h { |((source, entity_type), _normalizer), index| [[source, entity_type], index] }
        group.flat_map do |(source, entity_type), _normalizer|
          Models::SourceRecord.where(source:, entity_type:).to_a
        end.sort_by do |record|
          timestamp = record.source_updated_at || record.observed_at
          [timestamp.to_f, record.observed_at.to_f, record.entity_type.to_s,
            entity_order.fetch([record.source, record.entity_type]), record.id]
          end
        end
      end
    end
end
