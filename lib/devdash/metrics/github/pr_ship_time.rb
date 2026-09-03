# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Github
      class PrShipTime
        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.pr_ship_time_hours.v1", version: 1,
              name: "Pull request ship time", description: "Median elapsed time from pull request opening to merge",
              unit: "hours", value_type: "duration", signal_role: "outcome", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "lower_better", engthrive_section: "speed",
              framework_mappings: [
                { framework: "space", dimension: "performance", status: "measured" },
                { framework: "devex", dimension: "flow", status: "measured" }
              ], required_coverage: [{ source: "github", entity_type: "pull_request", scope: "repository" }]
            )
          end

          def call(person:, window:, repository_scope:)
            samples = Support.repositories(repository_scope).to_h do |repository|
              durations = qualifying_pull_requests(person, window, repository).filter_map do |pull_request|
                next unless pull_request.opened_at && pull_request.merged_at

                hours = (pull_request.merged_at - pull_request.opened_at) / 3600.0
                hours if hours >= 0
              end
              [repository.full_name, durations]
            end
            Support.duration_result(definition:, person:, window:, repository_scope:, samples_by_repository: samples)
          end

          private

          def qualifying_pull_requests(person, window, repository)
            Models::PullRequest.where(repository:, author_id: Support.person_id(person))
              .where("pull_requests.merged_at >= ? AND pull_requests.merged_at < ?", window.start_at, window.end_at)
              .where("pull_requests.opened_at IS NOT NULL")
              .where("pull_requests.base_branch = repositories.default_branch")
              .joins(:repository)
          end
        end
      end
    end
  end
end
