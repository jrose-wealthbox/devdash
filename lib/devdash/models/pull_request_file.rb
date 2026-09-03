# frozen_string_literal: true
module Devdash
  module Models
    class PullRequestFile < BaseRecord
      belongs_to :pull_request
    end
  end
end
