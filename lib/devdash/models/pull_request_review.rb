# frozen_string_literal: true
module Devdash
  module Models
    class PullRequestReview < BaseRecord
      belongs_to :pull_request
      belongs_to :reviewer, class_name: "Devdash::Models::Person", optional: true
    end
  end
end
