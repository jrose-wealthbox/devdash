# frozen_string_literal: true

require_relative "support"
require_relative "merged_pull_requests"

module Devdash
  module Metrics
    module Github
      class LinesShipped
        class << self
          def definition
            @definition ||= Support.definition(
              key: "github.lines_shipped.v1", version: 1,
              name: "Lines shipped", description: "Included additions and deletions in merged default-branch pull requests",
              unit: "lines", value_type: "count", signal_role: "outcome", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "higher_better", engthrive_section: "speed",
              framework_mappings: [
                { framework: "space", dimension: "performance", status: "measured" },
                { framework: "devex", dimension: "throughput", status: "measured" }
              ], required_coverage: [
                { source: "github", entity_type: "pull_request", scope: "repository" },
                { source: "github", entity_type: "pull_request_files", scope: "repository" }
              ]
            )
          end

          def call(person:, window:, repository_scope:)
            per_repository = {}
            totals = { included_additions: 0, included_deletions: 0, excluded_additions: 0, excluded_deletions: 0 }
            details = {}

            Support.repositories(repository_scope).each do |repository|
              additions = { included: 0, excluded: 0 }
              deletions = { included: 0, excluded: 0 }
              categories = Hash.new { |hash, key| hash[key] = { additions: 0, deletions: 0 } }
              qualifying_pull_requests(person, window, repository).find_each do |pull_request|
                pull_request.pull_request_files.each do |file|
                  bucket = file.exclusion_category.to_s.empty? ? :included : :excluded
                  additions[bucket] += Support.numeric(file.additions)
                  deletions[bucket] += Support.numeric(file.deletions)
                  next if bucket == :included

                  category = categories[file.exclusion_category.to_s]
                  category[:additions] += Support.numeric(file.additions)
                  category[:deletions] += Support.numeric(file.deletions)
                end
              end
              value = additions[:included] + deletions[:included]
              per_repository[repository.full_name] = value
              totals[:included_additions] += additions[:included]
              totals[:included_deletions] += deletions[:included]
              totals[:excluded_additions] += additions[:excluded]
              totals[:excluded_deletions] += deletions[:excluded]
              details[repository.full_name] = {
                value:, included_additions: additions[:included], included_deletions: deletions[:included],
                excluded_additions: additions[:excluded], excluded_deletions: deletions[:excluded],
                excluded_by_category: categories
              }
            end

            Support.count_result(definition:, person:, window:, repository_scope:, values: per_repository,
              sample_count: per_repository.values.sum,
              breakdown: totals.merge(repository_details: details))
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
