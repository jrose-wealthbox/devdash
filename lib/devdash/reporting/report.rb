# frozen_string_literal: true

require "time"

module Devdash
  module Reporting
    # Immutable, presentation-independent report envelope.  Metric rows are
    # hashes on purpose: they retain the query's repository breakdown and
    # diagnostic metadata without introducing a second lossy metric schema.
    Report = Data.define(
      :owner, :reported_at, :window, :previous_window, :repository_scope,
      :cohort, :sections, :coverage, :freshness, :framework_coverage,
      :partial_data_reasons, :cache_key, :cached
    ) do
      def current_window
        window
      end

      def report_timestamp
        reported_at
      end

      def metrics
        sections.values.flatten
      end

      def section(name)
        sections[name.to_s] || []
      end

      def to_h
        {
          "owner" => person_hash(owner),
          "reported_at" => reported_at&.utc&.iso8601(6),
          "window" => window_hash(window),
          "previous_window" => window_hash(previous_window),
          "repository_scope" => scope_hash(repository_scope),
          "cohort" => deep_json(cohort),
          "sections" => deep_json(sections),
          "coverage" => deep_json(coverage),
          "freshness" => deep_json(freshness),
          "framework_coverage" => deep_json(framework_coverage),
          "partial_data_reasons" => Array(partial_data_reasons),
          "cache_key" => cache_key,
          "cached" => !!cached
        }
      end

      def self.from_h(value)
        value = value.transform_keys(&:to_s)
        owner = value["owner"] || {}
        window = window_from_hash(value["window"])
        previous = window_from_hash(value["previous_window"])
        scope = value["repository_scope"] || {}
        scope = RepositoryScope.new(
          key: scope["key"], repository_names: Array(scope["repository_names"]),
          label: scope["label"], configuration_hash: scope["configuration_hash"]
        )
        new(
          owner:, reported_at: parse_time(value["reported_at"]), window:, previous_window: previous,
          repository_scope: scope, cohort: value["cohort"] || {}, sections: value["sections"] || {},
          coverage: value["coverage"] || {}, freshness: value["freshness"] || {},
          framework_coverage: value["framework_coverage"] || {},
          partial_data_reasons: Array(value["partial_data_reasons"]), cache_key: value["cache_key"],
          cached: value["cached"] == true
        )
      end

      class << self
        private

        def window_from_hash(value)
          value ||= {}
          Metrics::Window.new(
            key: value["key"], start_at: parse_time(value["start_at"]), end_at: parse_time(value["end_at"])
          )
        end

        def parse_time(value)
          return if value.nil?
          return value.utc if value.respond_to?(:utc)

          Time.iso8601(value.to_s).utc
        end
      end

      private

      def person_hash(person)
        return person if person.is_a?(Hash)
        return {} unless person

        { "id" => person.id, "display_name" => person.display_name }
      end

      def window_hash(value)
        {
          "key" => value.key.to_s,
          "start_at" => value.start_at.utc.iso8601(6),
          "end_at" => value.end_at.utc.iso8601(6)
        }
      end

      def scope_hash(value)
        {
          "key" => value.key.to_s,
          "repository_names" => Array(value.repository_names).map(&:to_s),
          "label" => value.label.to_s,
          "configuration_hash" => value.configuration_hash.to_s
        }
      end

      def deep_json(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = deep_json(item) }
        when Array then value.map { |item| deep_json(item) }
        when Data
          deep_json(value.to_h)
        when Time then value.utc.iso8601(6)
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
