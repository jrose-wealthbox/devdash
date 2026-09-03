# frozen_string_literal: true

module Devdash
  module Models
    class MetricDefinition < BaseRecord
      has_many :framework_mappings, class_name: "Devdash::Models::MetricFrameworkMapping",
        dependent: :delete_all, inverse_of: :metric_definition

      SIGNAL_ROLES = %w[outcome diagnostic activity guardrail].freeze
      MEASUREMENT_SCOPES = %w[individual team service].freeze
      COLLECTION_MODES = %w[telemetry self_report].freeze
      VALUE_TYPES = %w[count duration rate ratio currency score].freeze
      DIRECTIONS = %w[higher_better lower_better directionless].freeze
      COMPARISON_MODES = %w[person cohort team service].freeze
      ENTHRIVE_SECTIONS = %w[speed ease quality thriving].freeze

      validates :key, :name, :description, :unit, :value_type, :signal_role,
        :measurement_scope, :collection_mode, :directionality, :engthrive_section,
        presence: true
      validates :version, numericality: { only_integer: true, greater_than: 0 }
      validates :key, uniqueness: { scope: :version }
      validates :value_type, inclusion: { in: VALUE_TYPES }
      validates :signal_role, inclusion: { in: SIGNAL_ROLES }
      validates :measurement_scope, inclusion: { in: MEASUREMENT_SCOPES }
      validates :collection_mode, inclusion: { in: COLLECTION_MODES }
      validates :directionality, inclusion: { in: DIRECTIONS }
      validates :comparison_mode, inclusion: { in: COMPARISON_MODES }
      validates :engthrive_section, inclusion: { in: ENTHRIVE_SECTIONS }
      validate :service_dora_cannot_compare_people

      private

      def service_dora_cannot_compare_people
        return unless measurement_scope == "service" && comparison_mode == "person"

        dora = framework_mappings.to_a.any? { |mapping| mapping.framework.to_s == "dora" }
        errors.add(:comparison_mode, "service-scoped DORA metrics cannot compare people") if dora
      end
    end
  end
end
