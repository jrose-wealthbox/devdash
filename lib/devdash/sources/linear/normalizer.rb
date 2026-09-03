# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../../devdash"
require_relative "../../ingestion/canonical_json"
require_relative "../../models/linear_issue"
require_relative "../../models/linear_issue_event"
require_relative "../../models/issue_repository_link"
require_relative "../../models/source_identity"
require_relative "../../models/person"
require_relative "../../normalizers/registry"

module Devdash
  module Sources
    module Linear
      class Normalizer
        VERSION = 1
        TERMINAL_STATE_TYPES = %w[completed canceled cancelled].freeze
        OBSERVED_FIELDS = {
          "state" => ->(payload) { payload["state"] },
          "assignee" => ->(payload) { payload.dig("assignee", "id") },
          "estimate" => ->(payload) { payload["estimate"] },
          "project" => ->(payload) { payload.dig("project", "id") },
          "team" => ->(payload) { payload.dig("team", "id") },
          "title" => ->(payload) { payload["title"] }
        }.freeze

        attr_reader :version

        def initialize(clock: -> { Time.now.utc })
          @version = VERSION
          @clock = clock
        end

        def call(source_record)
          payload = JSON.parse(source_record.payload_json)
          case source_record.entity_type
          when "linear_issue"
            normalize_issue(source_record, payload)
          when "linear_issue_history"
            normalize_history(source_record, payload)
          end
        end

        def reset!
          Models::IssueRepositoryLink.delete_all
          Models::LinearIssueEvent.delete_all
          Models::LinearIssue.delete_all

          provisional = Models::SourceIdentity.where(source: "linear", resolution_method: "provisional")
          person_ids = provisional.distinct.pluck(:person_id)
          provisional.delete_all
          person_ids.each do |person_id|
            person = Models::Person.find_by(id: person_id)
            person.destroy! if person && removable_provisional_person?(person)
          rescue ActiveRecord::DeleteRestrictionError, ActiveRecord::InvalidForeignKey
            # A person may have acquired an independent reference while this
            # disposable Linear projection was being rebuilt.
          end
        end

        private

        def normalize_issue(record, payload)
          issue = Models::LinearIssue.find_or_initialize_by(linear_id: payload.fetch("id"))
          attributes = {
            identifier: payload.fetch("identifier"),
            title: payload.fetch("title"),
            url: payload["url"],
            team_id: payload.dig("team", "id"),
            team_name: payload.dig("team", "name"),
            project_id: payload.dig("project", "id"),
            project_name: payload.dig("project", "name"),
            state_id: payload.dig("state", "id"),
            state_name: payload.dig("state", "name"),
            state_type: payload.dig("state", "type"),
            creator_person: person_for(payload["creator"], observed_at: record.observed_at),
            creator_source_identity: payload.dig("creator", "id"),
            assignee_person: person_for(payload["assignee"], observed_at: record.observed_at),
            assignee_source_identity: payload.dig("assignee", "id"),
            estimate: payload["estimate"],
            created_at_source: parse_time(payload["createdAt"]),
            started_at_source: parse_time(payload["startedAt"]),
            completed_at_source: parse_time(payload["completedAt"]),
            canceled_at_source: parse_time(payload["canceledAt"]),
            source_updated_at: parse_time(payload["updatedAt"]),
            active: active_for(payload),
            # Keep the complete snapshot so fields added by Linear remain
            # inspectable even when they do not yet have typed columns.
            metadata_json: Ingestion::CanonicalJson.dump(payload)
          }

          # A replay can encounter records in any database insertion order.
          # Only the source-chronologically latest snapshot may move the
          # current projection backwards or forwards.
          issue.assign_attributes(attributes) if issue.new_record? || latest_issue_record?(record)
          issue.save!

          previous = predecessor_for(record)
          derive_changes(issue, record, previous, payload) if previous
          persist_attachment_evidence(issue, payload)
          issue
        end

        def normalize_history(record, payload)
          issue = Models::LinearIssue.find_by!(linear_id: payload.fetch("issue_id"))
          Array(payload["history"]).each do |event|
            persist_event(issue, event, "source_event", observed_at: record.observed_at)
          end
        end

        def active_for(payload)
          return false if payload["completedAt"] || payload["canceledAt"]

          !TERMINAL_STATE_TYPES.include?(payload.dig("state", "type").to_s.downcase)
        end

        def latest_issue_record?(record)
          records = Models::SourceRecord.where(source: "linear", entity_type: "linear_issue", external_id: record.external_id)
          records.to_a.max_by { |candidate| chronology_key(candidate) }&.id == record.id
        end

        def predecessor_for(record)
          Models::SourceRecord.where(source: "linear", entity_type: "linear_issue", external_id: record.external_id)
            .to_a.reject { |candidate| candidate.id == record.id }
            .select { |candidate| (chronology_key(candidate) <=> chronology_key(record)) == -1 }
            .max_by { |candidate| chronology_key(candidate) }
        end

        def chronology_key(record)
          timestamp = record.source_updated_at || payload_time(record)
          [timestamp&.to_f || -Float::INFINITY, record.observed_at.to_f, record.id.to_i]
        end

        def payload_time(record)
          payload = JSON.parse(record.payload_json)
          parse_time(payload["updatedAt"] || payload["occurredAt"] || payload["createdAt"])
        rescue JSON::ParserError
          nil
        end

        def derive_changes(issue, current_record, previous_record, current)
          previous = JSON.parse(previous_record.payload_json)
          current_hash = current_record.payload_hash || Ingestion::CanonicalJson.sha256(current)

          OBSERVED_FIELDS.each do |field, extractor|
            from = display_value(extractor.call(previous))
            to = display_value(extractor.call(current))
            next if from == to

            effective_at = source_time(current_record)
            material = [issue.linear_id, field, previous_record.payload_hash, current_hash, effective_at&.iso8601(6)].join("|")
            persist_event(issue,
              { "id" => Digest::SHA256.hexdigest(material), "type" => field,
                "createdAt" => effective_at&.iso8601(6), "from" => from, "to" => to },
              "observed_diff", observed_at: current_record.observed_at)
          end
        end

        def persist_event(issue, event, derivation, observed_at: nil)
          stable_id = event["id"].to_s
          stable_id = Digest::SHA256.hexdigest(Ingestion::CanonicalJson.dump(event)) if stable_id.empty?
          existing = issue.events.find_or_initialize_by(stable_external_id: stable_id)
          actor_payload = event["actor"] || (event["actorId"] && { "id" => event["actorId"] })
          actor = person_for(actor_payload, observed_at: observed_at)
          from, to = event_values(event)
          occurred_at = parse_time(event["createdAt"] || event["occurredAt"]) ||
            (existing.persisted? ? existing.occurred_at : observed_at || @clock.call)

          attributes = {
            kind: event["type"] || event["field"] || event["kind"] || (existing.kind || "unknown"),
            from_value: from.nil? && existing.persisted? ? existing.from_value : from,
            to_value: to.nil? && existing.persisted? ? existing.to_value : to,
            occurred_at: occurred_at,
            derivation: existing.persisted? ? existing.derivation : derivation,
            metadata_json: merged_event_metadata(existing, event)
          }
          if !existing.persisted? || (!manual_resolution_for?(existing.actor_person) && actor)
            attributes[:actor_person] = actor
          end
          existing.assign_attributes(attributes)
          existing.save!
          existing
        end

        def event_values(event)
          pairs = %w[
            from to fromValue toValue
            fromState toState fromAssignee toAssignee
            fromCycle toCycle
            fromParent toParent fromPriority toPriority
            fromEstimate toEstimate fromProject toProject
            fromTeam toTeam fromDueDate toDueDate
            fromDelegate toDelegate fromProjectMilestone toProjectMilestone
            fromSlaBreached toSlaBreached fromSlaBreachesAt toSlaBreachesAt
            fromSlaStartedAt toSlaStartedAt fromSlaType toSlaType
            fromAssigneeId toAssigneeId fromCycleId toCycleId
            fromParentId toParentId fromProjectId toProjectId
            fromStateId toStateId fromTeamId toTeamId fromTitle toTitle
          ]
          direct_from = event.key?("from") ? event["from"] : event["fromValue"]
          direct_to = event.key?("to") ? event["to"] : event["toValue"]
          if event.key?("from") || event.key?("fromValue") || event.key?("to") || event.key?("toValue")
            return [display_value(direct_from), display_value(direct_to)]
          end

          pairs.each_slice(2) do |from_key, to_key|
            next unless event.key?(from_key) || event.key?(to_key)

            return [display_value(event[from_key]), display_value(event[to_key])]
          end

          return [nil, display_value(event["addedLabelIds"])] if event.key?("addedLabelIds")
          return [display_value(event["removedLabelIds"]), nil] if event.key?("removedLabelIds")

          changes = event["changes"]
          if changes.is_a?(Hash)
            from = changes.key?("from") ? changes["from"] : changes["fromValue"]
            to = changes.key?("to") ? changes["to"] : changes["toValue"]
            if changes.key?("from") || changes.key?("fromValue") || changes.key?("to") || changes.key?("toValue")
              return [display_value(from), display_value(to)]
            end

            nested = changes.values.select { |value| value.is_a?(Hash) }
            if nested.length == 1
              from = nested.first.key?("from") ? nested.first["from"] : nested.first["fromValue"]
              to = nested.first.key?("to") ? nested.first["to"] : nested.first["toValue"]
              if nested.first.key?("from") || nested.first.key?("fromValue") || nested.first.key?("to") || nested.first.key?("toValue")
                return [display_value(from), display_value(to)]
              end
            end
          end
          [nil, nil]
        end

        def display_value(value)
          case value
          when Hash
            value["name"] || value["identifier"] || value["id"] || Ingestion::CanonicalJson.dump(value)
          when nil
            nil
          when Array
            Ingestion::CanonicalJson.dump(value)
          else
            value.to_s
          end
        end

        def merged_event_metadata(existing, event)
          previous = existing.persisted? && existing.metadata_json ? JSON.parse(existing.metadata_json) : {}
          previous = {} unless previous.is_a?(Hash)
          merged = previous.merge(event) { |_key, old_value, new_value| new_value.nil? ? old_value : new_value }
          Ingestion::CanonicalJson.dump(merged)
        rescue JSON::ParserError
          Ingestion::CanonicalJson.dump(event)
        end

        def person_for(identity, observed_at: nil)
          return nil unless identity.is_a?(Hash) && identity["id"]

          external_id = identity.fetch("id").to_s
          existing = Models::SourceIdentity.find_by(source: "linear", external_id: external_id)
          if existing
            update_identity_metadata(existing, identity, observed_at)
            return existing.person
          end

          person = Models::Person.create!(display_name: identity["name"].to_s.empty? ? external_id : identity["name"])
          Models::SourceIdentity.create!(person:, source: "linear", external_id:, login: identity["email"],
            normalized_email: normalize_email(identity["email"]), observed_display_name: identity["name"],
            resolution_method: "provisional", first_observed_at: observed_at || @clock.call,
            last_observed_at: observed_at || @clock.call)
          person
        end

        def update_identity_metadata(identity_record, payload, observed_at)
          attributes = {}
          attributes[:login] = payload["email"] if payload["email"]
          attributes[:normalized_email] = normalize_email(payload["email"]) if payload["email"]
          attributes[:observed_display_name] = payload["name"] if payload["name"]
          if observed_at
            attributes[:last_observed_at] = [identity_record.last_observed_at, observed_at].compact.max
          end
          identity_record.update!(attributes) unless attributes.empty?
        end

        def normalize_email(value)
          normalized = value.to_s.strip.downcase
          normalized unless normalized.empty?
        end

        def manual_resolution_for?(person)
          return false unless person

          person.source_identities.where(source: "linear").where.not(resolution_method: "provisional").exists?
        end

        def removable_provisional_person?(person)
          return false if person.owner? || person.organization_id || person.merged_into_id
          return false if person.source_identities.exists?
          return false if person.role_assignments.exists? || person.merged_people.exists?
          return false if person.person_merge_audits.exists? || person.source_person_merge_audits.exists?

          true
        end

        def persist_attachment_evidence(issue, payload)
          Array(payload.dig("attachments", "nodes")).each do |attachment|
            next unless attachment["url"]

            issue.issue_repository_links.create_or_find_by!(
              evidence_kind: "linear_attachment_url", evidence_reference: attachment["url"]
            ) do |link|
              link.assign_attributes(confidence: 0, primary: false, resolution_status: "unresolved")
            end
          end
        end

        def source_time(record)
          record.source_updated_at || payload_time(record) || record.observed_at
        end

        def parse_time(value)
          Time.iso8601(value).utc if value
        rescue ArgumentError, TypeError
          nil
        end
      end

      NORMALIZER = Normalizer.new

      def self.register_normalizer!
        %w[linear_issue linear_issue_history].each do |entity_type|
          Devdash::Normalizers::Registry.register(source: "linear", entity_type:, normalizer: NORMALIZER)
        rescue ArgumentError => error
          raise unless error.message.include?("already registered")
        end
      end
    end
  end
end
