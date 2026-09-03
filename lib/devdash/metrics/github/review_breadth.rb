# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Github
      class ReviewBreadth
        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.review_breadth.v1", version: 1,
              name: "Review breadth", description: "Distinct pull request authors helped by submitted reviews",
              unit: "people", value_type: "count", signal_role: "activity", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "directionless", engthrive_section: "thriving",
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
            per_repository = {}
            author_ids = []
            diagnostics = Hash.new(0)
            Support.repositories(repository_scope).each do |repository|
              Support.review_diagnostics(window:, repository:, owner_id: Support.person_id(person)).each do |key, count|
                diagnostics[key] += count
              end
              ids = submitted_reviews(person, window, repository).filter_map { |review| review.pull_request.author_id }.uniq
              author_ids.concat(ids)
              per_repository[repository.full_name] = ids.length
            end
            result = Support.count_result(definition:, person:, window:, repository_scope:, values: per_repository,
              sample_count: author_ids.uniq.length,
              breakdown: { distinct_authors: author_ids.uniq.length }.merge(diagnostics))
            result.with(value: author_ids.uniq.length)
          end

          private

          def submitted_reviews(person, window, repository)
            Models::PullRequestReview.joins(:pull_request)
              .where(pull_requests: { repository_id: repository.id }, reviewer_id: Support.person_id(person))
              .where("pull_request_reviews.submitted_at >= ? AND pull_request_reviews.submitted_at < ?", window.start_at, window.end_at)
              .where.not(submitted_at: nil)
              .where(state: %w[APPROVED COMMENTED CHANGES_REQUESTED approved commented changes_requested])
              .where.not(pull_requests: { author_id: Support.person_id(person) })
              .to_a.select do |review|
                Support.review_person_eligible?(review.reviewer_id) &&
                  review.pull_request.author_id &&
                  review.pull_request.author_id != Support.person_id(person)
              end
              .uniq { |review| [review.github_review_id.to_s, review.pull_request_id] }
          end
        end
      end
    end
  end
end
