# frozen_string_literal: true

module Devdash
  module Reporting
    class FrameworkCoverage
      FRAMEWORKS = %w[space devex dora].freeze
      STATUS_ORDER = { "unavailable" => 0, "partial" => 1, "measured" => 2 }.freeze

      def initialize(definitions: [], coverages: {})
        @definitions = Array(definitions)
        @coverages = coverages
      end

      def call
        result = {}
        FRAMEWORKS.each do |framework|
          dimensions = dimensions_for(framework)
          result[framework] = if framework == "dora"
            { "status" => "unavailable", "reason" => "unavailable in V1 (service-level source not configured)", "dimensions" => {} }
          else
            { "status" => overall_status(dimensions), "dimensions" => dimensions }
          end
        end
        result["thriving"] = {
          "status" => "unavailable",
          "reason" => "unavailable until private self-report is configured",
          "dimensions" => {}
        }
        result
      end

      private

      def dimensions_for(framework)
        mappings = @definitions.flat_map do |definition|
          Array(definition.framework_mappings).filter_map do |mapping|
            next unless mapping_value(mapping, :framework).to_s == framework

            [mapping_value(mapping, :dimension).to_s, mapping]
          end
        end
        mappings.group_by(&:first).sort.to_h do |dimension, pairs|
          statuses = pairs.map do |_name, mapping|
            declared = (mapping_value(mapping, :status) || "measured").to_s
            coverage_for(pairs, declared)
          end
          status = statuses.min_by { |item| STATUS_ORDER.fetch(item, 0) } || "unavailable"
          [dimension, { "status" => status, "proxy" => pairs.any? { |_name, mapping| mapping_value(mapping, :status).to_s == "proxy" } }]
        end
      end

      def coverage_for(pairs, declared)
        return "unavailable" if declared == "unavailable" || declared == "planned"
        declared = "measured" unless %w[measured partial unavailable planned].include?(declared)

        keys = pairs.filter_map do |_dimension, mapping|
          definition = @definitions.find { |candidate| Array(candidate.framework_mappings).include?(mapping) }
          definition && definition.key
        end
        states = keys.filter_map { |key| @coverages[key]&.fetch("status", nil) }
        return declared if states.empty?
        return "unavailable" if states.all? { |state| state == "unavailable" }
        return "partial" if states.any? { |state| state == "partial" || state == "unavailable" }

        declared == "partial" ? "partial" : "measured"
      end

      def overall_status(dimensions)
        values = dimensions.values.map { |item| item["status"] }
        return "unavailable" if values.empty?
        return "partial" if values.include?("partial")
        return "unavailable" if values.all? { |value| value == "unavailable" }

        "measured"
      end

      def mapping_value(mapping, key)
        return mapping.public_send(key) if mapping.respond_to?(key)
        return mapping[key] if mapping.respond_to?(:key?) && mapping.key?(key)
        return mapping[key.to_s] if mapping.respond_to?(:key?) && mapping.key?(key.to_s)

        nil
      end
    end
  end
end
