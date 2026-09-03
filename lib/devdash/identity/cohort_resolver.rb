# frozen_string_literal: true

require "active_record"
require "time"
require_relative "../../devdash"
require_relative "../models/person"
require_relative "../models/role_assignment"
require_relative "../models/repository"
require_relative "../models/pull_request"
require_relative "../models/pull_request_review"
require_relative "../models/commit"
require_relative "manual_configuration"

module Devdash
  module Identity
    class CohortResolver
      Result = Data.define(:included_ids, :exclusions, :role, :level) do
        def people
          Models::Person.where(id: included_ids).order(:id).to_a
        end

        def excluded
          exclusions
        end
      end
      ManualRole = Data.define(:normalized_role, :normalized_level, :effective_from, :effective_until, :source, :id)

      def initialize(configuration: nil)
        @configuration = configuration
      end

      def call(owner:, at:, repository_scope:)
        at = normalize_time(at)
        owner = owner.is_a?(Models::Person) ? owner : Models::Person.find(owner)
        owner_role = role_at(owner, at)
        exclusions = {}
        included = []

        Models::Person.order(:id).find_each do |person|
          reason = exclusion_reason(person, owner, owner_role, at, repository_scope)
          if reason
            exclusions[person.id] = reason
          else
            included << person.id
          end
        end

        Result.new(included_ids: included.sort.freeze, exclusions: exclusions.freeze,
          role: owner_role&.normalized_role || "unknown", level: owner_role&.normalized_level || "unknown")
      end

      private

      def exclusion_reason(person, owner, owner_role, at, repository_scope)
        return "owner" if person.id == owner.id
        return "merged" if person.merged_into_id
        return "inactive" unless person.active?
        return "bot" if person.bot?
        return "not_human" unless person.human?
        return "guest" if person.guest?
        return "unresolved" if person.source_identities.where(resolution_method: %w[unresolved provisional]).exists?
        return "excluded_by_configuration" if explicitly_excluded?(person)

        role = role_at(person, at)
        return "role_mismatch" unless owner_role && role &&
          role.normalized_role.to_s == owner_role.normalized_role.to_s &&
          role.normalized_level.to_s == owner_role.normalized_level.to_s &&
          role.normalized_role.to_s != "unknown" && role.normalized_level.to_s != "unknown"
        return "no_repository_activity" unless active_in_scope?(person, at, repository_scope)

        nil
      end

      def explicitly_excluded?(person)
        return false unless @configuration

        override = @configuration.people.values.find do |candidate|
          candidate.key.casecmp?(person.display_name.to_s) || (person.owner? && candidate.key == @configuration.owner) ||
            candidate.identities.any? do |source, external_id|
              person.source_identities.where(source:, external_id:).exists?
            end
        end
        override&.exclude_from_cohort == true
      end

      def role_at(person, at)
        manual_override = @configuration&.people&.values&.find do |candidate|
          candidate.key.casecmp?(person.display_name.to_s) || (person.owner? && candidate.key == @configuration.owner)
        end
        if manual_override && (manual_override.role || manual_override.level)
          return ManualRole.new(normalized_role: manual_override.role || "unknown", normalized_level: manual_override.level || "unknown",
            effective_from: Time.at(-9_223_372_036).utc, effective_until: nil, source: "manual", id: -1)
        end

        assignments = person.role_assignments.where("effective_from <= ?", at)
          .where("effective_until IS NULL OR effective_until > ?", at)
          .to_a
        assignment = assignments.max_by { |candidate| [source_priority(candidate.source), candidate.effective_from, candidate.id] }
        return assignment if assignment

        return unless manual_override&.role || manual_override&.level

        ManualRole.new(normalized_role: manual_override.role || "unknown", normalized_level: manual_override.level || "unknown",
          effective_from: Time.at(-9_223_372_036).utc, effective_until: nil, source: "manual", id: -1)
      end

      def source_priority(source)
        case source.to_s
        when "manual" then 3
        when "slack" then 2
        else 1
        end
      end

      def active_in_scope?(person, at, repository_scope)
        repository_ids = repository_ids_for(repository_scope)
        return true if repository_ids.empty?

        since = at - (180 * 24 * 60 * 60)
        Models::PullRequest.where(repository_id: repository_ids, author_id: person.id)
          .where("COALESCE(opened_at, source_updated_at) >= ? AND COALESCE(opened_at, source_updated_at) < ?", since, at).exists? ||
          Models::Commit.where(repository_id: repository_ids, author_id: person.id)
            .where("COALESCE(authored_at, committed_at) >= ? AND COALESCE(authored_at, committed_at) < ?", since, at).exists? ||
          Models::PullRequestReview.joins(:pull_request).where(pull_requests: { repository_id: repository_ids }, reviewer_id: person.id)
            .where("submitted_at >= ? AND submitted_at < ?", since, at).exists?
      end

      def repository_ids_for(scope)
        names = if scope.respond_to?(:repository_names)
          scope.repository_names
        elsif scope.to_s == "all" || scope == :all || scope.nil?
          return Models::Repository.where(enabled: true).pluck(:id)
        else
          Array(scope)
        end
        Models::Repository.where(enabled: true).where(full_name: names).or(
          Models::Repository.where(enabled: true).where(alias_name: names)
        ).pluck(:id).uniq
      end

      def normalize_time(value)
        value.respond_to?(:utc) ? value.utc : Time.parse(value.to_s).utc
      rescue ArgumentError
        raise ArgumentError, "at must be a timestamp"
      end
    end
  end
end
