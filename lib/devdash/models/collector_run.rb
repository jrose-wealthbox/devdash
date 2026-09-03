# frozen_string_literal: true

module Devdash
  module Models
    class CollectorRun < BaseRecord
      has_many :coverages, class_name: "Devdash::Models::CollectorRunCoverage",
        dependent: :restrict_with_exception
      has_many :source_records, dependent: :restrict_with_exception

      validates :source, :scope_key, :started_at, presence: true
      validates :status, inclusion: { in: %w[running succeeded partial failed] }
    end
  end
end
