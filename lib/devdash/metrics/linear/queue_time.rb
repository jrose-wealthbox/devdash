# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Linear
      class QueueTime
        include Support
        extend Support::ClassMethods

        class << self
          def definition
            @definition ||= Metrics::Definition.new(
              key: "linear.queue_time_hours.v1", version: 1, name: "Ticket queue time",
              description: "Elapsed UTC hours from issue creation to its first started transition for issues started in the window, attributed to the assignee at that transition.",
              unit: "hours", value_type: "duration", signal_role: "diagnostic", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "lower_better", engthrive_section: "speed",
              framework_mappings: [
                { framework: "space", dimension: "performance", status: "measured" },
                { framework: "devex", dimension: "flow_state", status: "proxy" },
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
          excluded = Hash.new(0)
          issue_rows(repository_scope).each do |issue, bucket|
            started = first_started(issue)
            unless started&.occurred_at
              excluded["missing_started_at"] += 1
              next
            end
            next unless window.include?(started.occurred_at)
            unless started.assignment_person_id == person_id
              excluded["unknown_or_different_assignee"] += 1 if started.assignment_person_id.nil?
              next
            end
            created_at = source_time(issue.created_at_source || issue[:created_at_source])
            unless created_at
              excluded["missing_created_at"] += 1
              next
            end
            hours = (started.occurred_at - created_at) / 3600.0
            if hours.negative?
              excluded["invalid_timestamp_order"] += 1
              next
            end
            rows << [issue, bucket, { hours: }]
          end
          duration_result(definition:, person_id:, window:, repository_scope:, rows:, excluded:)
        end
      end
    end
  end
end
