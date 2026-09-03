# frozen_string_literal: true

require_relative "window"
require_relative "weekday_normalizer"

module Devdash
  module Metrics
    Result = Data.define(
      :definition, :person_id, :window, :repository_scope,
      :value, :sample_count, :breakdown, :coverage
    ) do
      class << self
        alias_method :raw_new, :new

        def new(**attributes)
          attributes = attributes.dup
          attributes[:breakdown] = deep_freeze(attributes.fetch(:breakdown, {}))
          value = raw_new(**attributes)
          raise ArgumentError, "result sample_count must be a non-negative integer" unless value.sample_count.is_a?(Integer) && value.sample_count >= 0
          value
        end

        private

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, item| deep_freeze(key); deep_freeze(item) }
          when Array
            value.each { |item| deep_freeze(item) }
          end
          value.freeze
        end
      end

      def count?
        definition.value_type.to_s == "count"
      end

      def duration?
        definition.value_type.to_s == "duration"
      end

      def samples
        return [] unless breakdown.respond_to?(:fetch)

        breakdown[:samples] || breakdown["samples"] || (value.nil? ? [] : [value])
      end

      def weekday_rate
        return nil unless count? && value && (days = WeekdayNormalizer.equivalent_days(window))
        return nil if days.zero?

        value.to_f / days
      end

      alias activity_rate weekday_rate
    end
  end
end
