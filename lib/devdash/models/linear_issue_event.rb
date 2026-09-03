# frozen_string_literal: true

module Devdash
  module Models
    class LinearIssueEvent < BaseRecord
      belongs_to :linear_issue
      belongs_to :actor_person, class_name: "Devdash::Models::Person", optional: true
      validates :stable_external_id, :kind, :occurred_at, :derivation, presence: true
      validates :derivation, inclusion: { in: %w[source_event observed_diff] }
    end
  end
end
