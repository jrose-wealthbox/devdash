# frozen_string_literal: true
module Devdash
  module Models
    class PullRequest < BaseRecord
      belongs_to :repository
      belongs_to :author, class_name: "Devdash::Models::Person", optional: true
      has_many :pull_request_events, dependent: :delete_all
      has_many :pull_request_reviews, dependent: :delete_all
      has_many :pull_request_files, dependent: :delete_all
      has_many :commits, dependent: :nullify
    end
  end
end
