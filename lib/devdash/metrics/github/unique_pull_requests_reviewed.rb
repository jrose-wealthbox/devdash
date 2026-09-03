# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Github
      class UniquePullRequestsReviewed
        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.unique_prs_reviewed.v1", version: 1,
              name: "Unique pull requests reviewed", description: "Distinct non-self pull requests receiving a submitted review",
              unit: "pull requests", value_type: "count", signal_role: "activity", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "directionless", engthrive_section: "ease",
              framework_mappings: [
                { framework: "space", dimension: "collaboration", status: "measured" },
                { framework: "devex", dimension: "feedback", status: "measured" }
              ], required_coverage: [
                { source: "github", entity_type: "pull_request_reviews", scope: "repository" },
                { source: "github", entity_type: "pull_request", scope: "repository" }
              ]
            )
          end

          def call(person:, window:, repository_scope:)
            diagnostics = Hash.new(0)
            values = Support.repositories(repository_scope).to_h do |repository|
              Support.review_diagnostics(window:, repository:, owner_id: Support.person_id(person)).each do |key, count|
                diagnostics[key] += count
              end
              reviews = submitted_reviews(person, window, repository)
              [repository.full_name, reviews.map(&:pull_request_id).uniq.length]
            end
            Support.count_result(definition:, person:, window:, repository_scope:, values:, breakdown: diagnostics)
          end

          private

          def submitted_reviews(person, window, repository)
            Models::PullRequestReview.joins(:pull_request)
              .where(pull_requests: { repository_id: repository.id }, reviewer_id: Support.person_id(person))
              .where("pull_request_reviews.submitted_at >= ? AND pull_request_reviews.submitted_at < ?", window.start_at, window.end_at)
              .where("pull_request_reviews.submitted_at IS NOT NULL")
              .where(state: %w[APPROVED COMMENTED CHANGES_REQUESTED approved commented changes_requested])
              .where.not(pull_requests: { author_id: Support.person_id(person) })
              .to_a.select { |review| Support.review_person_eligible?(review.reviewer_id) }
          end
        end
      end
    end
  end
end
