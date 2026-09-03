# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Github
      class DirectPushLines
        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.direct_push_lines.v1", version: 1,
              name: "Direct push lines", description: "Lines changed by reachable non-merge commits without a pull request",
              unit: "lines", value_type: "count", signal_role: "diagnostic", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "directionless", engthrive_section: "ease",
              framework_mappings: [
                { framework: "space", dimension: "activity", status: "measured" },
                { framework: "devex", dimension: "delivery", status: "diagnostic" }
              ], required_coverage: [
                { source: "github", entity_type: "commit", scope: "repository" },
                { source: "github", entity_type: "commit_files", scope: "repository" }
              ]
            )
          end

          def call(person:, window:, repository_scope:)
            per_repository = {}
            details = {}
            Support.repositories(repository_scope).each do |repository|
              commits = Models::Commit.where(repository:, author_id: Support.person_id(person),
                default_branch_reachable: true, pull_request_id: nil)
                .where("commits.committed_at >= ? AND commits.committed_at < ?", window.start_at, window.end_at)
                .where("commits.parent_count <= 1")
              additions = 0
              deletions = 0
              commits.find_each do |commit|
                commit.commit_files.each do |file|
                  additions += Support.numeric(file.additions)
                  deletions += Support.numeric(file.deletions)
                end
              end
              per_repository[repository.full_name] = additions + deletions
              details[repository.full_name] = { value: additions + deletions, additions:, deletions:, commit_count: commits.distinct.count(:id) }
            end
            Support.count_result(definition:, person:, window:, repository_scope:, values: per_repository,
              sample_count: per_repository.values.sum,
              breakdown: { repository_details: details })
          end
        end
      end
    end
  end
end
