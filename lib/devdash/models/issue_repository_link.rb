# frozen_string_literal: true

module Devdash
  module Models
    class IssueRepositoryLink < BaseRecord
      belongs_to :linear_issue
      belongs_to :repository, optional: true
      validates :evidence_kind, :evidence_reference, :resolution_status, presence: true
    end
  end
end
