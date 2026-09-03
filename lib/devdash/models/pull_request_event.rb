# frozen_string_literal: true
module Devdash
  module Models
    class PullRequestEvent < BaseRecord
      belongs_to :pull_request
      belongs_to :actor, class_name: "Devdash::Models::Person", optional: true
      belongs_to :subject, class_name: "Devdash::Models::Person", optional: true
    end
  end
end
