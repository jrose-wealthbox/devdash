# frozen_string_literal: true

require "active_record"
require_relative "../../devdash"
require_relative "../models/person"
require_relative "../models/person_merge_audit"
require_relative "../models/source_identity"
require_relative "../models/role_assignment"
require_relative "../models/pull_request"
require_relative "../models/pull_request_event"
require_relative "../models/pull_request_review"
require_relative "../models/commit"
require_relative "../models/linear_issue"
require_relative "../models/linear_issue_event"

module Devdash
  module Identity
    class PersonMerger
      # These are intentionally explicit. A new canonical reference must be
      # added here during schema review rather than being silently overlooked
      # because it happens to be named *_person_id.
      PERSON_FOREIGN_KEYS = {
        "source_identities" => %w[person_id],
        "role_assignments" => %w[person_id],
        "pull_requests" => %w[author_id],
        "pull_request_events" => %w[actor_id subject_id],
        "pull_request_reviews" => %w[reviewer_id],
        "commits" => %w[author_id committer_id],
        "linear_issues" => %w[creator_person_id assignee_person_id],
        "linear_issue_events" => %w[actor_person_id]
      }.freeze

      class << self
        def call(**attributes)
          new(**attributes).call
        end
      end

      def initialize(source_person:, destination_person:, reason:, evidence_reference:, clock: -> { Time.now.utc })
        @source_person = source_person
        @destination_person = destination_person
        @reason = reason.to_s
        @evidence_reference = evidence_reference.to_s
        @clock = clock
      end

      def call
        return @destination_person if @source_person.id == @destination_person.id

        Models::Person.transaction do
          source = Models::Person.lock.find(@source_person.id)
          destination = Models::Person.lock.find(@destination_person.id)
          if source.merged_into_id && source.merged_into_id != destination.id
            raise ConfigurationError, "person #{source.id} is already merged into another destination"
          end

          unless source.merged_into_id == destination.id
            update_foreign_keys!(source.id, destination.id)
            source.update!(active: false, merged_into_id: destination.id)
          end

          Models::PersonMergeAudit.find_or_create_by!(
            source_person_id: source.id, destination_person_id: destination.id,
            reason: @reason, evidence_reference: @evidence_reference
          ) do |audit|
            audit.merged_at = @clock.call
          end
        end

        @destination_person.reload
      end

      private

      def update_foreign_keys!(source_id, destination_id)
        connection = Models::Person.connection
        PERSON_FOREIGN_KEYS.each do |table_name, columns|
          next unless connection.table_exists?(table_name)

          model = model_for_table(table_name)
          columns.each do |column|
            next unless connection.column_exists?(table_name, column)

            model.where(column => source_id).update_all(column => destination_id)
          end
        end
      end

      def model_for_table(table_name)
        case table_name
        when "source_identities" then Models::SourceIdentity
        when "role_assignments" then Models::RoleAssignment
        else
          "Devdash::Models::#{table_name.singularize.camelize}".constantize
        end
      end
    end
  end
end
