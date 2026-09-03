# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Linear
      class CompletedWhileAssigned
        include Support
        extend Support::ClassMethods

        class << self
          def definition
            @definition ||= Metrics::Definition.new(
              key: "linear.completed_while_assigned.v1", version: 1, name: "Tickets completed while assigned",
              description: "Terminal completed periods whose assignee at the transition was the person; this does not claim transition authorship.",
              unit: "tickets", value_type: "count", signal_role: "outcome", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "higher_better", engthrive_section: "speed",
              framework_mappings: [
                { framework: "space", dimension: "performance", status: "measured" },
                { framework: "engthrive", dimension: "speed", status: "measured" }
              ], required_coverage: [
                { source: "linear", entity_type: "linear_issue", scope: "global" },
                { source: "linear", entity_type: "linear_issue_history", scope: "global" }
              ]
            )
          end
        end

        def call(person:, window:, repository_scope:)
          person_id = person_id_for(person)
          rows = []
          unknown_assignee = 0
          issue_rows(repository_scope).each do |issue, bucket|
            completion_periods(issue).each do |period|
              next unless window.include?(period.occurred_at)
              unknown_assignee += 1 if period.assignment_person_id.nil?
              next unless period.assignment_person_id == person_id

              rows << [issue, bucket, period]
            end
          end
          issue_ids = rows.map(&:first).map(&:linear_id).uniq
          recompleted = rows.count { |_issue, _bucket, period| period.ordinal > 1 }
          count_result(definition:, person_id:, window:, repository_scope:, rows:,
            extra: { distinct_issues: issue_ids.length, recompleted_periods: recompleted, unknown_assignee: })
        end
      end
    end
  end
end
