# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Github
      class ReviewsSubmitted
        STATES = {
          "APPROVED" => :approved,
          "COMMENTED" => :commented,
          "CHANGES_REQUESTED" => :changes_requested
        }.freeze

        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.reviews_submitted.v1", version: 1,
              name: "Reviews submitted", description: "Distinct submitted pull request reviews authored by the person",
              unit: "reviews", value_type: "count", signal_role: "activity", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "directionless", engthrive_section: "ease",
              framework_mappings: [
                { framework: "space", dimension: "communication", status: "measured" },
                { framework: "devex", dimension: "feedback", status: "measured" }
              ], required_coverage: [
                { source: "github", entity_type: "pull_request_reviews", scope: "repository" },
                { source: "github", entity_type: "pull_request", scope: "repository" }
              ]
            )
          end

          def call(person:, window:, repository_scope:)
            per_repository = {}
            totals = { approved: 0, commented: 0, changes_requested: 0 }
            diagnostics = Hash.new(0)
            Support.repositories(repository_scope).each do |repository|
              counts = Hash.new(0)
              Support.review_diagnostics(window:, repository:, owner_id: Support.person_id(person)).each do |key, count|
                diagnostics[key] += count
              end
              submitted_reviews(person, window, repository).each do |review|
                state = STATES[review.state.to_s.upcase]
                next unless state

                counts[state] += 1
                totals[state] += 1
              end
              per_repository[repository.full_name] = counts.values.sum
            end
            Support.count_result(definition:, person:, window:, repository_scope:, values: per_repository,
              sample_count: per_repository.values.sum, breakdown: totals.merge(diagnostics))
          end

          private

          def submitted_reviews(person, window, repository)
            Models::PullRequestReview.joins(:pull_request)
              .where(pull_requests: { repository_id: repository.id }, reviewer_id: Support.person_id(person))
              .where("pull_request_reviews.submitted_at >= ? AND pull_request_reviews.submitted_at < ?", window.start_at, window.end_at)
              .where.not(submitted_at: nil)
              .where(state: STATES.keys + STATES.keys.map(&:downcase))
              .where.not(pull_requests: { author_id: Support.person_id(person) })
              .to_a.select { |review| Support.review_person_eligible?(review.reviewer_id) }
              .uniq { |review| review.github_review_id.to_s }
          end
        end
      end
    end
  end
end
