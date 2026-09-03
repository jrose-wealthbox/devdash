# frozen_string_literal: true

module Devdash
  module Models
    class MetricFrameworkMapping < BaseRecord
      belongs_to :metric_definition, inverse_of: :framework_mappings

      FRAMEWORKS = %w[engthrive space devex dora].freeze
      STATUSES = %w[measured partial unavailable planned].freeze

      validates :framework, :dimension, :status, presence: true
      validates :framework, inclusion: { in: FRAMEWORKS }
      validates :status, inclusion: { in: STATUSES }
      validates :dimension, uniqueness: { scope: %i[metric_definition_id framework] }
    end
  end
end
