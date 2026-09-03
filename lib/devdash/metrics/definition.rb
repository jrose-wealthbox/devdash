# frozen_string_literal: true

module Devdash
  module Metrics
    Definition = Data.define(
      :key, :version, :name, :description, :unit, :value_type,
      :signal_role, :measurement_scope, :collection_mode,
      :directionality, :engthrive_section, :framework_mappings,
      :required_coverage
    ) do
      SECTIONS = %w[speed ease quality thriving].freeze
      SIGNAL_ROLES = %w[outcome diagnostic activity guardrail].freeze
      MEASUREMENT_SCOPES = %w[individual team service].freeze
      COLLECTION_MODES = %w[telemetry self_report].freeze
      DIRECTIONS = %w[higher_better lower_better directionless].freeze
      VALUE_TYPES = %w[count duration rate ratio currency score].freeze

      class << self
        alias_method :raw_new, :new

        def new(**attributes)
          attributes = attributes.dup
          attributes[:framework_mappings] = deep_freeze(attributes.fetch(:framework_mappings, []))
          attributes[:required_coverage] = deep_freeze(attributes.fetch(:required_coverage, []))
          value = raw_new(**attributes)
          validate!(value)
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

        def validate!(value)
          raise ArgumentError, "metric key is required" if value.key.to_s.strip.empty?
          raise ArgumentError, "metric version must be a positive integer" unless value.version.is_a?(Integer) && value.version.positive?
          raise ArgumentError, "metric name is required" if value.name.to_s.strip.empty?
          raise ArgumentError, "metric description is required" if value.description.to_s.strip.empty?
          raise ArgumentError, "metric unit is required" if value.unit.to_s.strip.empty?
          raise ArgumentError, "invalid metric value type" unless VALUE_TYPES.include?(value.value_type.to_s)
          raise ArgumentError, "invalid metric signal role" unless SIGNAL_ROLES.include?(value.signal_role.to_s)
          raise ArgumentError, "invalid metric measurement scope" unless MEASUREMENT_SCOPES.include?(value.measurement_scope.to_s)
          raise ArgumentError, "invalid metric collection mode" unless COLLECTION_MODES.include?(value.collection_mode.to_s)
          raise ArgumentError, "invalid metric directionality" unless DIRECTIONS.include?(value.directionality.to_s)
          raise ArgumentError, "invalid EngThrive section" unless SECTIONS.include?(value.engthrive_section.to_s)
          raise ArgumentError, "framework mappings must be an array" unless value.framework_mappings.is_a?(Array)
          raise ArgumentError, "required coverage must be an array" unless value.required_coverage.is_a?(Array)
        end
      end

      def active?
        true
      end
    end
  end
end
