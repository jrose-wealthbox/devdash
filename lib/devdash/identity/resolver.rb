# frozen_string_literal: true

require "active_record"
require "set"
require_relative "../../devdash"
require_relative "../models/person"
require_relative "../models/source_identity"
require_relative "../models/organization"
require_relative "manual_configuration"
require_relative "person_merger"

module Devdash
  module Identity
    class Resolver
      Result = Data.define(:merged_count, :unresolved_count, :ambiguous_count, :ambiguous_emails, :unresolved_identities) do
        def merged
          merged_count
        end

        def unresolved
          unresolved_count
        end

        def ambiguous
          ambiguous_count
        end
      end

      def initialize(configuration:, clock: -> { Time.now.utc })
        @configuration = configuration
        @clock = clock
      end

      def call
        merged = 0
        ambiguous_emails = []
        ambiguous_people = Set.new

        targets = materialize_manual_people
        manual_identity_targets = explicit_identity_targets(targets)
        collision_keys = explicit_email_collisions(manual_identity_targets)

        manual_identity_targets.keys.sort.each do |identity_key|
          identity = find_identity(identity_key)
          next unless identity
          next if collision_keys.include?(identity_key)

          destination = targets.fetch(manual_identity_targets.fetch(identity_key))
          if identity.person_id != destination.id
            PersonMerger.new(source_person: identity.person, destination_person: destination,
              reason: "manual identity override", evidence_reference: evidence_reference(identity_key), clock: @clock).call
            merged += 1
          end
          identity.reload.update!(resolution_method: "manual", confidence: 1.0)
        end

        email_groups.each do |email, identities|
          people = identities.map(&:person_id).uniq.reject { |id| merged_person_id?(id) }
          next if people.length <= 1

          explicit_targets = identities.filter_map do |identity|
            target_key = manual_identity_targets[[identity.source, identity.external_id]]
            target_key && targets.fetch(target_key).id
          end.uniq
          next if explicit_targets.length == 1

          ambiguous_emails << email
          people.each { |id| ambiguous_people << id }
        end

        email_groups.each do |_email, identities|
          people = identities.map(&:person_id).uniq.reject { |id| ambiguous_people.include?(id) || merged_person_id?(id) }
          next unless people.length == 2

          explicit_targets = identities.filter_map do |identity|
            target_key = manual_identity_targets[[identity.source, identity.external_id]]
            target_key && targets.fetch(target_key).id
          end.uniq
          destination = Models::Person.find(explicit_targets.first || people.min)
          identities.map(&:person_id).uniq.reject { |id| id == destination.id }.each do |source_id|
            source = Models::Person.find(source_id)
            PersonMerger.new(source_person: source, destination_person: destination,
              reason: "exact normalized verified email", evidence_reference: "email:#{identities.first.normalized_email}", clock: @clock).call
            merged += 1
          end
          identities.each { |identity| identity.reload.update!(resolution_method: "email", confidence: 0.95) }
        end

        unresolved = Models::SourceIdentity.where(resolution_method: "unresolved").order(:source, :external_id).to_a
        Result.new(merged_count: merged, unresolved_count: unresolved.length,
          ambiguous_count: ambiguous_emails.length, ambiguous_emails: ambiguous_emails.freeze,
          unresolved_identities: unresolved.map { |identity| [identity.source, identity.external_id] }.freeze)
      end

      private

      def materialize_manual_people
        @configuration.people.each_with_object({}) do |(key, override), people|
          person = if key == @configuration.owner
            Models::Person.find_by(owner: true)
          end
          person ||= Models::Person.where("lower(display_name) = ?", key.downcase).first
          person ||= override.identities.lazy.map do |source, external_id|
            Models::SourceIdentity.find_by(source:, external_id:).then { |identity| identity&.person }
          end.find(&:itself)
          person ||= Models::Person.create!(display_name: key.tr("-_", "  ").split.map(&:capitalize).join(" "), owner: key == @configuration.owner)
          person.update!(owner: true) if key == @configuration.owner && !person.owner?
          people[key] = person
        end
      end

      def explicit_identity_targets(targets)
        @configuration.people.each_with_object({}) do |(key, override), mappings|
          override.identities.each do |source, external_id|
            mappings[[source, external_id]] = key
          end
        end
      end

      def explicit_email_collisions(identity_targets)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        identity_targets.each do |identity_key, target_key|
          identity = find_identity(identity_key)
          next unless identity&.normalized_email.to_s != ""

          grouped[identity.normalized_email] << [identity_key, target_key]
        end
        grouped.values.filter_map do |entries|
          target_keys = entries.map(&:last).uniq
          next unless target_keys.length > 1

          entries.map(&:first)
        end.flatten(1).to_set
      end

      def email_groups
        Models::SourceIdentity.where.not(normalized_email: [nil, ""]).order(:normalized_email, :id).to_a
          .group_by { |identity| identity.normalized_email.to_s.strip.downcase }
      end

      def find_identity(identity_key)
        source, external_id = identity_key
        Models::SourceIdentity.find_by(source:, external_id:)
      end

      def evidence_reference(identity_key)
        "config:#{@configuration.path || "people.yml"}:#{identity_key.join(":")}"
      end

      def merged_person_id?(id)
        Models::Person.where(id:).where.not(merged_into_id: nil).exists?
      end
    end
  end
end
