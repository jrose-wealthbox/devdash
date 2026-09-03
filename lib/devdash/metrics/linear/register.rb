# frozen_string_literal: true

require_relative "tickets_created"
require_relative "completed_while_assigned"
require_relative "queue_time"
require_relative "active_cycle_time"
require_relative "end_to_end_time"
require_relative "reopened_tickets"

module Devdash
  module Metrics
    module Linear
      module Register
        QUERIES = [
          TicketsCreated, CompletedWhileAssigned, QueueTime,
          ActiveCycleTime, EndToEndTime, ReopenedTickets
        ].freeze

        module_function

        def call(registry)
          QUERIES.each_with_index do |query, index|
            registry.register(query:, definition: query.definition, display_order: index)
          end
          registry
        end
      end
    end
  end
end
