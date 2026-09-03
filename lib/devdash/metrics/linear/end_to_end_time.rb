# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Linear
      class EndToEndTime
        include Support
        extend Support::ClassMethods

        class << self
          def definition
            @definition ||= Metrics::Definition.new(
              key: "linear.end_to_end_time_hours.v1", version: 1, name: "Ticket end-to-end time",
              description: "Elapsed UTC hours from issue creation to each qualifying completed period, attributed to the assignee at completion.",
              unit: "hours", value_type: "duration", signal_role: "diagnostic", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "lower_better", engthrive_section: "speed",
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
          excluded = Hash.new(0)
          issue_rows(repository_scope).each do |issue, bucket|
            completion_periods(issue).each do |completion|
              next unless window.include?(completion.occurred_at)
              next unless completion.assignment_person_id == person_id
              if completion.assignment_person_id.nil?
                excluded["unknown_assignee"] += 1
                next
              end
              created_at = source_time(issue.created_at_source || issue[:created_at_source])
              unless created_at
                excluded["missing_created_at"] += 1
                next
              end
              hours = (completion.occurred_at - created_at) / 3600.0
              if hours.negative?
                excluded["invalid_timestamp_order"] += 1
                next
              end
              rows << [issue, bucket, { hours:, completion_period: completion.ordinal }]
            end
          end
          duration_result(definition:, person_id:, window:, repository_scope:, rows:, excluded:)
        end
      end
    end
  end
end
