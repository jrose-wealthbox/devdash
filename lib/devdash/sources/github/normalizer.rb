# frozen_string_literal: true

require "json"
require "set"
require "time"
require "active_record"
require_relative "../../models/base_record"
require_relative "../../models/organization"
require_relative "../../models/person"
require_relative "../../models/person_merge_audit"
require_relative "../../models/source_identity"
require_relative "../../models/role_assignment"
require_relative "../../models/repository"
require_relative "../../models/pull_request"
require_relative "../../models/pull_request_event"
require_relative "../../models/pull_request_review"
require_relative "../../models/pull_request_file"
require_relative "../../models/commit"
require_relative "../../models/commit_file"
require_relative "../../normalizers/registry"

module Devdash
  module Sources
    module Github
      class Normalizer
        VERSION = 2
        DEFAULT_EXCLUSION_GLOBS = [
          ["**/vendor/**", "vendor"], ["vendor/**", "vendor"],
          ["**/generated/**", "generated"], ["generated/**", "generated"],
          ["**/*.lock", "lockfile"], ["*.lock", "lockfile"]
        ].freeze
        ENTITY_TYPES = %w[
          repository pull_request pull_request_reviews pull_request_timeline
          pull_request_events pull_request_files commit commit_files
        ].freeze

        attr_reader :version

        def initialize(exclusion_globs: nil)
          @version = VERSION
          @exclusion_globs = DEFAULT_EXCLUSION_GLOBS + configured_globs(exclusion_globs)
        end

        def call(record)
          payload = JSON.parse(record.payload_json)
          case record.entity_type
          when "repository" then normalize_repository(record.scope_key, payload)
          when "pull_request" then normalize_pull(record.scope_key, record, payload)
          when "pull_request_reviews" then normalize_reviews(record.scope_key, record, payload)
          when "pull_request_timeline", "pull_request_events" then normalize_events(record.scope_key, record, payload)
          when "pull_request_files" then normalize_files(record.scope_key, record, payload)
          when "commit" then normalize_commit(record.scope_key, record, payload)
          when "commit_files" then normalize_commit_files(record.scope_key, record, payload)
          end
        end

        def reset!
          ActiveRecord::Base.transaction do
            Models::PullRequestFile.delete_all
            Models::PullRequestReview.delete_all
            Models::PullRequestEvent.delete_all
            Models::CommitFile.delete_all
            Models::Commit.update_all(pull_request_id: nil)
            Models::Commit.delete_all
            Models::PullRequest.delete_all
            remove_provisional_identities!
          end
        end

        private

        def repository(name)
          Models::Repository.find_or_create_by!(source: "github", full_name: name) do |repo|
            repo.alias_name = name.split("/").last
          end
        end

        def person(login, email: nil, observed_at:)
          login = nonempty(login)
          email = normalized_email(email)
          return nil if login.nil? && email.nil?

          external = login || email
          identity = if login
            Models::SourceIdentity.find_by(source: "github", external_id: external)
          else
            identities = email_identities(email)
            identities.one? ? identities.first : nil
          end
          if identity
            identity.update!(
              login: login || identity.login,
              normalized_email: email || identity.normalized_email,
              observed_display_name: login || identity.observed_display_name,
              first_observed_at: [identity.first_observed_at, observed_at].compact.min,
              last_observed_at: [identity.last_observed_at, observed_at].compact.max
            )
            return identity.person
          end

          return nil if login.nil? && email_identities(email).length > 1

          person = Models::Person.create!(display_name: login || email)
          Models::SourceIdentity.create!(
            person:, source: "github", external_id: external,
            login:, normalized_email: email,
            observed_display_name: login, resolution_method: "provisional",
            first_observed_at: observed_at, last_observed_at: observed_at
          )
          person
        end

        def normalize_repository(name, payload)
          repo = repository(name)
          repo.update!(
            external_id: payload["node_id"], default_branch: payload["default_branch"],
            archived: payload["archived"] == true, metadata_json: JSON.generate(payload)
          )
        end

        def normalize_pull(name, record, payload)
          repo = repository(name)
          pr = Models::PullRequest.find_or_initialize_by(repository: repo, number: payload.fetch("number"))
          user = payload["user"] || {}
          pr.update!(
            node_id: payload["node_id"], author: person(user["login"], observed_at: record.observed_at), author_login: nonempty(user["login"]),
            state: payload["state"], draft: payload["draft"] == true,
            base_branch: payload.dig("base", "ref"), head_sha: payload.dig("head", "sha"),
            merge_sha: payload["merge_commit_sha"], opened_at: parse_time(payload["created_at"]),
            closed_at: parse_time(payload["closed_at"]), merged_at: parse_time(payload["merged_at"]),
            source_updated_at: parse_time(payload["updated_at"]), additions: payload["additions"],
            deletions: payload["deletions"], changed_files_count: payload["changed_files"]
          )
        end

        def pull(name, number)
          Models::PullRequest.find_by!(repository: repository(name), number: number)
        end

        def normalize_reviews(name, record, payload)
          Array(payload).sort_by { |review| review["id"].to_s }.each do |review|
            next unless review["id"]

            number = review["_pull_number"] || pull_number(record.external_id) || review.dig("pull_request", "number")
            next unless number

            pr = pull(name, number)
            user = review["user"] || {}
            Models::PullRequestReview.find_or_initialize_by(github_review_id: review.fetch("id").to_s).update!(
              pull_request: pr, reviewer: person(user["login"], observed_at: record.observed_at), reviewer_login: nonempty(user["login"]),
              state: review["state"], submitted_at: parse_time(review["submitted_at"])
            )
          end
        end

        def normalize_events(name, record, payload)
          Array(payload).sort_by { |event| event["id"].to_s }.each do |event|
            next unless event["id"]

            number = event["_pull_number"] || pull_number(record.external_id) || event.dig("issue", "number") || event["number"]
            next unless number

            pr = pull(name, number)
            actor = event["actor"] || event["user"] || {}
            requested = event["requested_reviewer"] || {}
            Models::PullRequestEvent.find_or_initialize_by(
              pull_request: pr, stable_external_id: event["id"].to_s
            ).update!(
              kind: event["event"] || event["type"], actor: person(actor["login"], observed_at: record.observed_at), actor_login: nonempty(actor["login"]),
              subject: person(requested["login"], observed_at: record.observed_at), subject_login: nonempty(requested["login"]),
              occurred_at: parse_time(event["created_at"]), derivation: "github_timeline"
            )
          end
        end

        def normalize_files(name, record, payload)
          files = Array(payload)
          number = pull_number(record.external_id) || files.first&.dig("_pull_number") || files.first&.dig("pull_request", "number")
          return unless number

          pr = pull(name, number)
          pr.pull_request_files.delete_all
          files.sort_by { |file| file.fetch("filename") }.each do |file|
            pr.pull_request_files.create!(
              path: file.fetch("filename"), status: file["status"], additions: file["additions"] || 0,
              deletions: file["deletions"] || 0, exclusion_category: exclusion(file.fetch("filename"))
            )
          end
        end

        def normalize_commit(name, record, payload)
          repo = repository(name)
          author = payload.dig("commit", "author") || {}
          committer = payload.dig("commit", "committer") || {}
          commit = Models::Commit.find_or_initialize_by(repository: repo, sha: payload.fetch("sha"))
          reachable = commit.default_branch_reachable || payload["default_branch_reachable"] == true
          commit.update!(
            author: person(payload.dig("author", "login"), email: author["email"], observed_at: record.observed_at),
            committer: person(payload.dig("committer", "login"), email: committer["email"], observed_at: record.observed_at),
            author_login: nonempty(payload.dig("author", "login")) || commit.author_login,
            author_email: normalized_email(author["email"]) || commit.author_email,
            committer_login: nonempty(payload.dig("committer", "login")) || commit.committer_login,
            committer_email: normalized_email(committer["email"]) || commit.committer_email,
            authored_at: parse_time(author["date"]), committed_at: parse_time(committer["date"]),
            parent_count: Array(payload["parents"]).length, default_branch_reachable: reachable,
            pull_request: pull_for_commit(name, payload)
          )
        end

        def normalize_commit_files(name, record, payload)
          normalize_commit(name, record, payload)
          commit = Models::Commit.find_by!(repository: repository(name), sha: payload.fetch("sha"))
          commit.commit_files.delete_all
          Array(payload["files"]).sort_by { |file| file.fetch("filename") }.each do |file|
            commit.commit_files.create!(
              path: file.fetch("filename"), status: file["status"], additions: file["additions"] || 0,
              deletions: file["deletions"] || 0, exclusion_category: exclusion(file.fetch("filename"))
            )
          end
        end

        def pull_for_commit(name, payload)
          number = payload["pull_request_number"] || payload.dig("pull_request", "number")
          number && pull(name, number)
        end

        def exclusion(path)
          normalized = path.to_s.tr("\\", "/")
          @exclusion_globs.each do |pattern, category|
            return category if glob_match?(pattern, normalized)
          rescue ArgumentError
            next
          end
          nil
        end

        def glob_match?(pattern, path)
          flags = File::FNM_PATHNAME | File::FNM_EXTGLOB
          return true if File.fnmatch?(pattern, path, flags)

          prefix = pattern.to_s.delete_suffix("/**")
          pattern.to_s.end_with?("/**") && path.start_with?("#{prefix}/")
        end

        def configured_globs(globs)
          case globs
          when Hash
            globs.each_with_object([]) do |(category, patterns), entries|
              Array(patterns).each { |pattern| entries << [pattern.to_s, category.to_s] }
            end
          else
            Array(globs).map { |pattern| [pattern.to_s, configured_category(pattern)] }
          end
        end

        def configured_category(pattern)
          value = pattern.to_s.downcase
          return "vendor" if value.include?("vendor")
          return "generated" if value.include?("generated")
          return "lockfile" if value.end_with?(".lock") || value.include?("*.lock")

          "configured"
        end

        def nonempty(value)
          value = value.to_s.strip
          value unless value.empty?
        end

        def normalized_email(value)
          nonempty(value)&.downcase
        end

        def email_identities(email)
          return [] if email.nil?

          Models::SourceIdentity.where(source: "github", normalized_email: email).limit(2).to_a
        end

        def pull_number(external_id)
          external_id.to_s[/pull_(?:files|reviews|event):([0-9]+)\z/, 1]&.to_i
        end

        def parse_time(value)
          return value.utc if value.respond_to?(:utc)
          return if value.to_s.empty?

          Time.iso8601(value.to_s).utc
        rescue ArgumentError, TypeError
          nil
        end

        def remove_provisional_identities!
          provisional_methods = %w[provisional unresolved]
          github_identities = Models::SourceIdentity.where(source: "github")
          deletable_people = Models::Person
            .where(id: github_identities.where(resolution_method: provisional_methods).select(:person_id))
            .where.not(id: github_identities.where.not(resolution_method: provisional_methods).select(:person_id))
            .where.not(id: Models::SourceIdentity.where.not(source: "github").select(:person_id))
            .where(owner: false, merged_into_id: nil)
            .where.not(id: Models::Person.where.not(merged_into_id: nil).select(:merged_into_id))
            .where.not(id: Models::PersonMergeAudit.select(:source_person_id))
            .where.not(id: Models::PersonMergeAudit.select(:destination_person_id))
            .where.not(id: Models::RoleAssignment.where.not(source: "github").select(:person_id))
          person_ids = deletable_people.pluck(:id)

          Models::RoleAssignment.where(source: "github").delete_all
          Models::SourceIdentity.where(source: "github", person_id: person_ids).delete_all
          Models::Person.where(id: person_ids).delete_all
        end
      end

      NORMALIZER = Normalizer.new unless const_defined?(:NORMALIZER, false)

      def self.register_normalizer!
        Normalizer::ENTITY_TYPES.each do |entity_type|
          begin
            existing = Devdash::Normalizers::Registry.fetch(source: "github", entity_type: entity_type)
            next if existing.equal?(NORMALIZER)
            raise ArgumentError, "normalizer already registered for github:#{entity_type}"
          rescue KeyError
            Devdash::Normalizers::Registry.register(source: "github", entity_type:, normalizer: NORMALIZER)
          end
        end
        NORMALIZER
      end
    end
  end
end

Devdash::Sources::GitHub = Devdash::Sources::Github unless Devdash::Sources.const_defined?(:GitHub, false)
Devdash::Sources::Github.register_normalizer!
