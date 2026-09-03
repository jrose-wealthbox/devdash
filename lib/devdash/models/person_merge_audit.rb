# frozen_string_literal: true

module Devdash
  module Models
    class PersonMergeAudit < BaseRecord
      self.table_name = "person_merge_audits"

      belongs_to :source_person, class_name: "Devdash::Models::Person"
      belongs_to :destination_person, class_name: "Devdash::Models::Person"

      validates :reason, :evidence_reference, :merged_at, presence: true
    end
  end
end
