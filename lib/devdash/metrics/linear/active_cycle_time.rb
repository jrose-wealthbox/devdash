# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Linear
      class ActiveCycleTime
        include Support
        extend Support::ClassMethods

        class << self
          def definition
            @definition ||= Metrics::Definition.new(
              key: "linear.active_cycle_time_hours.v1", version: 1, name: "Ticket active cycle time",
              description: "Elapsed UTC hours from first started to each completed period, subtracting only explicitly bounded non-started intervals; otherwise the result is an elapsed approximation.",
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
          approximated = 0
          issue_rows(repository_scope).each do |issue, bucket|
            completion_periods(issue).each do |completion|
              next unless window.include?(completion.occurred_at)
              next unless completion.assignment_person_id == person_id
              if completion.assignment_person_id.nil?
                excluded["unknown_assignee"] += 1
                next
              end

              hours, approximate = active_cycle_hours(issue, completion)
              unless hours
                excluded["missing_started_at"] += 1
                next
              end
              approximated += 1 if approximate
              rows << [issue, bucket, { hours:, completion_period: completion.ordinal, approximated: approximate }]
            end
          end
          duration_result(definition:, person_id:, window:, repository_scope:, rows:, excluded:,
            extra: { approximated_samples: approximated, approximation_note: "elapsed unless history supplies complete pause boundaries" })
        end
      end
    end
  end
end
