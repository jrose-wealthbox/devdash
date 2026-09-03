# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Github
      class ReviewPickupTime
        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.review_pickup_time_hours.v1", version: 1,
              name: "Review pickup time", description: "Median time from a reviewer request to their first submitted review",
              unit: "hours", value_type: "duration", signal_role: "diagnostic", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "lower_better", engthrive_section: "speed",
              framework_mappings: [
                { framework: "space", dimension: "communication", status: "measured" },
                { framework: "devex", dimension: "feedback_loop_coverage", status: "measured" }
              ], required_coverage: [
                { source: "github", entity_type: "pull_request_events", scope: "repository" },
                { source: "github", entity_type: "pull_request_reviews", scope: "repository" }
              ]
            )
          end

          def call(person:, window:, repository_scope:)
            samples = {}
            diagnostics = Hash.new(0)
            Support.repositories(repository_scope).each do |repository|
              Support.review_diagnostics(window:, repository:, owner_id: Support.person_id(person)).each do |key, count|
                diagnostics[key] += count
              end
              repository_samples = []
              eligible_reviews(person, window, repository).group_by(&:pull_request_id).each_value do |reviews|
                request = first_request_for_pull_request(reviews.first, person)
                review = reviews.select { |candidate| request && candidate.submitted_at > request.occurred_at }
                  .min_by(&:submitted_at)
                unless request
                  diagnostics[:without_request] += 1
                  next
                end
                next unless review

                repository_samples << (review.submitted_at - request.occurred_at) / 3600.0
              end
              samples[repository.full_name] = repository_samples.select { |hours| hours >= 0 }
            end
            Support.duration_result(definition:, person:, window:, repository_scope:, samples_by_repository: samples,
              breakdown: diagnostics)
          end

          private

          def eligible_reviews(person, window, repository)
            Models::PullRequestReview.joins(:pull_request)
              .where(pull_requests: { repository_id: repository.id }, reviewer_id: Support.person_id(person))
              .where("pull_request_reviews.submitted_at >= ? AND pull_request_reviews.submitted_at < ?", window.start_at, window.end_at)
              .where.not(submitted_at: nil)
              .where(state: %w[APPROVED COMMENTED CHANGES_REQUESTED approved commented changes_requested])
              .where.not(pull_requests: { author_id: Support.person_id(person) })
              .to_a.select { |review| Support.review_person_eligible?(review.reviewer_id) }
              .uniq { |review| review.pull_request_id }
          end

          def first_request_for_pull_request(review, person)
            review.pull_request.pull_request_events
              .where(subject_id: Support.person_id(person))
              .where.not(occurred_at: nil)
              .to_a.select { |event| event.kind.to_s.downcase.match?(/review.*request/) }
              .min_by(&:occurred_at)
          end
        end
      end
    end
  end
end
