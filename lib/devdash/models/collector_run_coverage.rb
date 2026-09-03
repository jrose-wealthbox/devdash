# frozen_string_literal: true

module Devdash
  module Models
    class CollectorRunCoverage < BaseRecord
      self.table_name = "collector_run_coverages"
      belongs_to :collector_run
      validates :scope_type, :scope_key, :entity_type, presence: true
      validates :status, inclusion: { in: %w[complete partial failed] }
    end
  end
end
