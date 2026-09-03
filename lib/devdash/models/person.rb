# frozen_string_literal: true

module Devdash
  module Models
    class Person < BaseRecord
      belongs_to :organization, optional: true
      belongs_to :merged_into, class_name: "Devdash::Models::Person", optional: true
      has_many :merged_people, class_name: "Devdash::Models::Person", foreign_key: :merged_into_id,
        inverse_of: :merged_into, dependent: :restrict_with_exception
      has_many :source_identities, dependent: :restrict_with_exception
      has_many :role_assignments, dependent: :restrict_with_exception
      has_many :person_merge_audits, foreign_key: :destination_person_id,
        inverse_of: :destination_person, dependent: :restrict_with_exception
      has_many :source_person_merge_audits, class_name: "Devdash::Models::PersonMergeAudit",
        foreign_key: :source_person_id, inverse_of: :source_person, dependent: :restrict_with_exception

      validates :display_name, presence: true
    end
  end
end
