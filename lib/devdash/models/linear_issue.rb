# frozen_string_literal: true

module Devdash
  module Models
    class LinearIssue < BaseRecord
      has_many :events, class_name: "Devdash::Models::LinearIssueEvent", dependent: :delete_all
      has_many :issue_repository_links, dependent: :delete_all
      belongs_to :creator_person, class_name: "Devdash::Models::Person", optional: true
      belongs_to :assignee_person, class_name: "Devdash::Models::Person", optional: true
      validates :linear_id, :identifier, :title, presence: true
    end
  end
end
