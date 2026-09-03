# frozen_string_literal: true

require_relative "merged_pull_requests"
require_relative "pr_ship_time"
require_relative "authored_commits"
require_relative "lines_shipped"
require_relative "direct_push_lines"
require_relative "unique_pull_requests_reviewed"
require_relative "reviews_submitted"
require_relative "review_breadth"
require_relative "review_pickup_time"

module Devdash
  module Metrics
    module Github
      module Register
        QUERIES = [
          MergedPullRequests, PrShipTime, AuthoredCommits, LinesShipped, DirectPushLines,
          UniquePullRequestsReviewed, ReviewsSubmitted, ReviewBreadth, ReviewPickupTime
        ].freeze

        module_function

        def call(registry)
          QUERIES.each { |query| registry.register(query:) }
          registry
        end
      end
    end
  end
end
