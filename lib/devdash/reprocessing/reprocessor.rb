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
        run_ids = []
        runs = entries.map do |(source, entity_type), normalizer|
          run = Models::NormalizationRun.create!(
            normalizer_key: "#{source}:#{entity_type}", normalizer_version: normalizer.version,
            status: "running", started_at: Time.now.utc
          )
          run_ids << run.id
          run
        end

        ActiveRecord::Base.transaction do
          runs.each_with_index do |run, index|
            (source, entity_type), normalizer = entries[index]
            normalizer.reset! if normalizer.respond_to?(:reset!)
            records = ordered_records(source, entity_type)
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

      def ordered_records(source, entity_type)
        Models::SourceRecord.where(source: source, entity_type: entity_type)
          .order(Arel.sql("COALESCE(source_updated_at, observed_at) ASC, observed_at ASC, id ASC"))
      end
    end
  end
end
