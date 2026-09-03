# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Github
      class AuthoredCommits
        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.authored_commits.v1", version: 1,
              name: "Authored commits", description: "Distinct non-merge commits authored on the default branch",
              unit: "commits", value_type: "count", signal_role: "activity", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "directionless", engthrive_section: "speed",
              framework_mappings: [
                { framework: "space", dimension: "activity", status: "measured" },
                { framework: "devex", dimension: "throughput", status: "measured" }
              ], required_coverage: [{ source: "github", entity_type: "commit", scope: "repository" }]
            )
          end

          def call(person:, window:, repository_scope:)
            values = Support.repositories(repository_scope).to_h do |repository|
              relation = Models::Commit.where(repository:, author_id: Support.person_id(person), default_branch_reachable: true)
                .where("commits.committed_at >= ? AND commits.committed_at < ?", window.start_at, window.end_at)
                .where("commits.parent_count <= 1")
              [repository.full_name, relation.distinct.count(:id)]
            end
            Support.count_result(definition:, person:, window:, repository_scope:, values:)
          end
        end
      end
    end
  end
end
