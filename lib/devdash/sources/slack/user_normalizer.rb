# frozen_string_literal: true

require "json"

module Devdash
  module Sources
    module Slack
      module UserNormalizer
        VERSION = 1
        module_function

        def version
          VERSION
        end

        def call(source_record)
          payload = source_record.payload_json ? JSON.parse(source_record.payload_json) : {}
          external_id = payload.fetch("id")
          profile = payload.fetch("profile", {})
          observed_at = source_record.observed_at
          effective_at = source_record.source_updated_at || observed_at
          display_name = [profile["display_name"], profile["real_name"], payload["real_name"], payload["name"]].find { |value| value && !value.strip.empty? } || external_id
          email = profile["email"].to_s.strip.downcase
          bot = payload["is_bot"] == true
          guest = payload["is_restricted"] == true || payload["is_ultra_restricted"] == true
          human = !bot
          active = payload["deleted"] != true

          identity = Models::SourceIdentity.find_or_initialize_by(source: "slack", external_id: external_id)
          person = identity.person || Models::Person.create!(display_name: display_name, active: active, human: human, bot: bot, guest: guest)
          identity.person = person
          identity_attributes = {
            login: payload["name"],
            normalized_email: email.empty? ? nil : email,
            observed_display_name: display_name,
            last_observed_at: observed_at
          }
          if identity.new_record?
            identity_attributes[:first_observed_at] = observed_at
            identity_attributes[:resolution_method] = "unresolved"
          end
          identity.assign_attributes(identity_attributes)
          identity.save!

          person.update!(display_name: display_name, active: active, human: human, bot: bot, guest: guest)
          title = profile["title"].to_s
          current = person.role_assignments.where(source: "slack", effective_until: nil).order(effective_from: :desc).first
          if title.strip.empty?
            current&.update!(effective_until: effective_at)
          else
            unless current && current.original_title == title
              current&.update!(effective_until: effective_at)
              person.role_assignments.create!(source: "slack", original_title: title,
                normalized_role: "unknown", normalized_level: "unknown",
                effective_from: effective_at, observed_at: observed_at)
            end
          end
          person
        end

        def reset!
          ActiveRecord::Base.transaction do
            slack_identities = Models::SourceIdentity.where(source: "slack")
            deletable_people = Models::Person
              .where(id: slack_identities.where(resolution_method: "unresolved").select(:person_id))
              .where.not(id: slack_identities.where.not(resolution_method: "unresolved").select(:person_id))
              .where.not(id: Models::SourceIdentity.where.not(source: "slack").select(:person_id))
              .where(owner: false, merged_into_id: nil)
              .where.not(id: Models::Person.where.not(merged_into_id: nil).select(:merged_into_id))
              .where.not(id: Models::PersonMergeAudit.select(:source_person_id))
              .where.not(id: Models::PersonMergeAudit.select(:destination_person_id))
              .where.not(id: Models::RoleAssignment.where.not(source: "slack").select(:person_id))
            deletable_person_ids = deletable_people.pluck(:id)

            Models::RoleAssignment.where(source: "slack").delete_all
            Models::SourceIdentity.where(source: "slack", person_id: deletable_person_ids).delete_all
            Models::Person.where(id: deletable_person_ids).delete_all
          end
        end
      end
    end
  end
end
