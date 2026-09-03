# frozen_string_literal: true

require_relative "support"

module Devdash
  module Metrics
    module Linear
      class TicketsCreated
        include Support
        extend Support::ClassMethods

        class << self
          def definition
            @definition ||= Metrics::Definition.new(
              key: "linear.tickets_created.v1", version: 1, name: "Tickets created",
              description: "Issues created by the person during the report window.", unit: "tickets",
              value_type: "count", signal_role: "activity", measurement_scope: "individual",
              collection_mode: "telemetry", directionality: "directionless", engthrive_section: "speed",
              framework_mappings: [
                { framework: "space", dimension: "performance", status: "measured" },
                { framework: "engthrive", dimension: "speed", status: "measured" }
              ], required_coverage: [{ source: "linear", entity_type: "linear_issue", scope: "global" }]
            )
          end
        end

        def call(person:, window:, repository_scope:)
          person_id = person_id_for(person)
          rows = issue_rows(repository_scope).filter_map do |issue, bucket|
            next unless issue.creator_person_id == person_id
            created_at = source_time(issue.created_at_source || issue[:created_at_source])
            next unless created_at && window.include?(created_at)

            [issue, bucket, nil]
          end
          count_result(definition:, person_id:, window:, repository_scope:, rows:)
        end
      end
    end
  end
end
