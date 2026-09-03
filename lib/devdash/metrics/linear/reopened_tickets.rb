# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Linear
      class ReopenedTickets
        include Support
        extend Support::ClassMethods

        class << self
          def definition
            @definition ||= Metrics::Definition.new(
              key: "linear.reopened_tickets.v1", version: 1, name: "Reopened tickets",
              description: "Completed issues that returned to a non-terminal state while assigned to the person; diagnostic context, not a negative score.",
              unit: "tickets", value_type: "count", signal_role: "diagnostic", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "directionless", engthrive_section: "quality",
              framework_mappings: [
                { framework: "space", dimension: "performance", status: "measured" },
                { framework: "engthrive", dimension: "quality", status: "measured" }
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
            reopened_periods(issue).each do |period|
              next unless window.include?(period.occurred_at)
              unknown_assignee += 1 if period.assignment_person_id.nil?
              next unless period.assignment_person_id == person_id

              rows << [issue, bucket, period]
            end
          end
          count_result(definition:, person_id:, window:, repository_scope:, rows:, extra: { unknown_assignee: })
        end
      end
    end
  end
end
