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
          display_name = [profile["display_name"], profile["real_name"], payload["real_name"], payload["name"]].find { |value| value && !value.strip.empty? } || external_id
          email = profile["email"].to_s.strip.downcase
          bot = payload["is_bot"] == true
          guest = payload["is_restricted"] == true || payload["is_ultra_restricted"] == true
          human = !bot
          active = payload["deleted"] != true

          identity = Models::SourceIdentity.find_or_initialize_by(source: "slack", external_id: external_id)
          person = identity.person || Models::Person.create!(display_name: display_name, active: active, human: human, bot: bot, guest: guest)
          identity.person = person
          identity.assign_attributes(
            normalized_email: email.empty? ? nil : email,
            observed_display_name: display_name,
            last_observed_at: observed_at,
            resolution_method: "unresolved"
          )
          identity.save!

          person.update!(display_name: display_name, active: active, human: human, bot: bot, guest: guest)
          title = profile["title"].to_s
          if !title.empty?
            current = person.role_assignments.where(source: "slack", effective_until: nil).order(effective_from: :desc).first
            unless current && current.original_title == title
              current&.update!(effective_until: observed_at)
              person.role_assignments.create!(source: "slack", original_title: title,
                normalized_role: "unknown", normalized_level: "unknown",
                effective_from: observed_at, observed_at: observed_at)
            end
          end
          person
        end

        def reset!
          slack_people = Models::SourceIdentity.where(source: "slack").distinct.pluck(:person_id)
          Models::RoleAssignment.where(source: "slack").delete_all
          Models::SourceIdentity.where(source: "slack").delete_all
          Models::Person.where(id: slack_people).where.not(id: Models::SourceIdentity.select(:person_id)).delete_all
        end
      end
    end
  end
end
