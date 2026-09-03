# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Github
      class MergedPullRequests
        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.merged_pull_requests.v1", version: 1,
              name: "Merged pull requests", description: "Authored pull requests merged into a repository's default branch",
              unit: "pull requests", value_type: "count", signal_role: "outcome", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "higher_better", engthrive_section: "speed",
              framework_mappings: [
                { framework: "space", dimension: "performance", status: "measured" },
                { framework: "devex", dimension: "delivery", status: "measured" }
              ], required_coverage: [{ source: "github", entity_type: "pull_request", scope: "repository" }]
            )
          end

          def call(person:, window:, repository_scope:)
            values = Support.repositories(repository_scope).to_h do |repository|
              count = qualifying_pull_requests(person, window, repository).count
              [repository.full_name, count]
            end
            Support.count_result(definition:, person:, window:, repository_scope:, values:)
          end

          private

          def qualifying_pull_requests(person, window, repository)
            Models::PullRequest.where(repository:, author_id: Support.person_id(person))
              .where("pull_requests.merged_at >= ? AND pull_requests.merged_at < ?", window.start_at, window.end_at)
              .where("pull_requests.base_branch = repositories.default_branch")
              .joins(:repository)
          end
        end
      end
    end
  end
end
