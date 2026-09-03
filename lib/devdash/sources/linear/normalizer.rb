# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../ingestion/canonical_json"

module Devdash
  module Sources
    module Linear
      class Normalizer
        VERSION = 1
        attr_reader :version

        def initialize
          @version = VERSION
        end

        def call(source_record)
          payload = JSON.parse(source_record.payload_json)
          if source_record.entity_type == "linear_issue"
            normalize_issue(source_record, payload)
          elsif source_record.entity_type == "linear_issue_history"
            normalize_history(source_record, payload)
          end
        end

        def reset!
          Models::IssueRepositoryLink.delete_all
          Models::LinearIssueEvent.delete_all
          Models::LinearIssue.delete_all
          ids = Models::SourceIdentity.where(source: "linear").pluck(:person_id)
          Models::SourceIdentity.where(source: "linear").delete_all
          ids.uniq.each do |person_id|
            person = Models::Person.find_by(id: person_id)
            person&.destroy! if person && person.source_identities.none?
          end
        end

        private

        def normalize_issue(record, payload)
          issue = Models::LinearIssue.find_or_initialize_by(linear_id: payload.fetch("id"))
          previous = Models::SourceRecord.where(source: "linear", entity_type: "linear_issue", external_id: record.external_id)
            .where.not(id: record.id).order(observed_at: :desc).first
          issue.assign_attributes(
            identifier: payload.fetch("identifier"), title: payload.fetch("title"), url: payload["url"],
            team_id: payload.dig("team", "id"), team_name: payload.dig("team", "name"),
            project_id: payload.dig("project", "id"), project_name: payload.dig("project", "name"),
            state_id: payload.dig("state", "id"), state_name: payload.dig("state", "name"), state_type: payload.dig("state", "type"),
            creator_person: person_for(payload["creator"]), creator_source_identity: payload.dig("creator", "id"),
            assignee_person: person_for(payload["assignee"]), assignee_source_identity: payload.dig("assignee", "id"),
            estimate: payload["estimate"], created_at_source: parse_time(payload["createdAt"]),
            started_at_source: parse_time(payload["startedAt"]), completed_at_source: parse_time(payload["completedAt"]),
            canceled_at_source: parse_time(payload["canceledAt"]), source_updated_at: parse_time(payload["updatedAt"]),
            active: payload.key?("active") ? payload["active"] : payload["completedAt"].nil? && payload["canceledAt"].nil?,
            metadata_json: Ingestion::CanonicalJson.dump(payload.slice("labels", "attachments"))
          )
          issue.save!
          derive_changes(issue, previous, payload) if previous
          persist_attachment_evidence(issue, payload)
          issue
        end

        def normalize_history(record, payload)
          issue = Models::LinearIssue.find_by!(linear_id: payload.fetch("issue_id"))
          Array(payload["history"]).each { |event| persist_event(issue, event, "source_event") }
        end

        def derive_changes(issue, previous_record, current)
          previous = JSON.parse(previous_record.payload_json)
          fields = [["state", previous.dig("state", "name"), current.dig("state", "name")], ["assignee", previous.dig("assignee", "id"), current.dig("assignee", "id")]]
          fields.each do |field, from, to|
            next if from == to
            material = [issue.linear_id, field, previous_record.payload_hash, Ingestion::CanonicalJson.sha256(current), current["updatedAt"]].join("|")
            id = Digest::SHA256.hexdigest(material)
            persist_event(issue, { "id" => id, "type" => field, "createdAt" => current["updatedAt"], "from" => from, "to" => to }, "observed_diff")
          end
        end

        def persist_event(issue, event, derivation)
          stable_id = event.fetch("id").to_s
          from = event["from"] || event.dig("fromState", "name") || event.dig("fromAssignee", "id")
          to = event["to"] || event.dig("toState", "name") || event.dig("toAssignee", "id")
          actor = person_for(event["actor"])
          issue.events.create_or_find_by!(stable_external_id: stable_id) do |candidate|
            candidate.assign_attributes(kind: event.fetch("type", "unknown"), actor_person: actor, from_value: from, to_value: to,
              occurred_at: parse_time(event["createdAt"]) || Time.now.utc, derivation: derivation,
              metadata_json: Ingestion::CanonicalJson.dump(event))
          end
        end

        def person_for(identity)
          return nil unless identity.is_a?(Hash) && identity["id"]
          source_identity = Models::SourceIdentity.find_by(source: "linear", external_id: identity["id"])
          return source_identity.person if source_identity
          person = Models::Person.create!(display_name: identity["name"].to_s.empty? ? identity["id"] : identity["name"])
          Models::SourceIdentity.create!(person:, source: "linear", external_id: identity["id"], login: identity["email"],
            normalized_email: identity["email"]&.downcase, observed_display_name: identity["name"], resolution_method: "provisional")
          person
        end

        def persist_attachment_evidence(issue, payload)
          Array(payload.dig("attachments", "nodes")).each do |attachment|
            next unless attachment["url"]
            issue.issue_repository_links.create_or_find_by!(evidence_kind: "linear_attachment_url", evidence_reference: attachment["url"]) do |link|
              link.assign_attributes(confidence: 0, primary: false, resolution_status: "unresolved")
            end
          end
        end

        def parse_time(value)
          Time.iso8601(value).utc if value
        rescue ArgumentError
          nil
        end
      end

      NORMALIZER = Normalizer.new
      def self.register_normalizer!
        Devdash::Normalizers::Registry.register(source: "linear", entity_type: "linear_issue", normalizer: NORMALIZER)
        Devdash::Normalizers::Registry.register(source: "linear", entity_type: "linear_issue_history", normalizer: NORMALIZER)
      rescue ArgumentError => error
        raise unless error.message.include?("already registered")
      end
    end
  end
end
