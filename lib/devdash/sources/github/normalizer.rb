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
        VERSION = 1
        DEFAULT_EXCLUSION_GLOBS = [
          ["**/vendor/**", "vendor"], ["vendor/**", "vendor"],
          ["**/generated/**", "generated"], ["generated/**", "generated"],
          ["**/*.lock", "lockfile"], ["*.lock", "lockfile"]
        ].freeze
        ENTITY_TYPES = %w[
          repository pull_request pull_request_reviews pull_request_timeline
          pull_request_files commit commit_files
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
          when "pull_request" then normalize_pull(record.scope_key, payload)
          when "pull_request_reviews" then normalize_reviews(record.scope_key, record, payload)
          when "pull_request_timeline", "pull_request_events" then normalize_events(record.scope_key, record, payload)
          when "pull_request_files" then normalize_files(record.scope_key, record, payload)
          when "commit" then normalize_commit(record.scope_key, payload)
          when "commit_files" then normalize_commit_files(record.scope_key, payload)
          end
        end

        def reset!
          Models::PullRequestFile.delete_all
          Models::PullRequestReview.delete_all
          Models::PullRequestEvent.delete_all
          Models::CommitFile.delete_all
          Models::Commit.update_all(pull_request_id: nil)
          Models::Commit.delete_all
          Models::PullRequest.delete_all
          remove_provisional_identities!
        end

        private

        def repository(name)
          Models::Repository.find_or_create_by!(source: "github", full_name: name) do |repo|
            repo.alias_name = name.split("/").last
          end
        end

        def person(login, email: nil)
          login = login.to_s.strip
          email = email.to_s.strip
          return nil if login.empty? && email.empty?

          external = login.empty? ? email : login
          identity = Models::SourceIdentity.find_by(source: "github", external_id: external)
          if identity
            identity.update!(last_observed_at: Time.now.utc, login: nonempty(login), normalized_email: nonempty(email))
            return identity.person
          end

          person = Models::Person.create!(display_name: login.empty? ? email : login)
          Models::SourceIdentity.create!(
            person:, source: "github", external_id: external,
            login: nonempty(login), normalized_email: nonempty(email),
            observed_display_name: nonempty(login), resolution_method: "provisional"
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

        def normalize_pull(name, payload)
          repo = repository(name)
          pr = Models::PullRequest.find_or_initialize_by(repository: repo, number: payload.fetch("number"))
          user = payload["user"] || {}
          pr.update!(
            node_id: payload["node_id"], author: person(user["login"]), author_login: user["login"],
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
              pull_request: pr, reviewer: person(user["login"]), reviewer_login: user["login"],
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
              kind: event["event"] || event["type"], actor: person(actor["login"]), actor_login: actor["login"],
              subject: person(requested["login"]), subject_login: requested["login"],
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

        def normalize_commit(name, payload)
          repo = repository(name)
          author = payload.dig("commit", "author") || {}
          committer = payload.dig("commit", "committer") || {}
          commit = Models::Commit.find_or_initialize_by(repository: repo, sha: payload.fetch("sha"))
          reachable = commit.default_branch_reachable || payload["default_branch_reachable"] == true
          commit.update!(
            author: person(payload.dig("author", "login"), email: author["email"]),
            committer: person(payload.dig("committer", "login"), email: committer["email"]),
            author_login: payload.dig("author", "login"), author_email: author["email"],
            committer_login: payload.dig("committer", "login"), committer_email: committer["email"],
            authored_at: parse_time(author["date"]), committed_at: parse_time(committer["date"]),
            parent_count: Array(payload["parents"]).length, default_branch_reachable: reachable,
            pull_request: pull_for_commit(name, payload)
          )
        end

        def normalize_commit_files(name, payload)
          normalize_commit(name, payload)
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
          value unless value.to_s.empty?
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
          identities = Models::SourceIdentity.where(source: "github", resolution_method: %w[provisional unresolved])
          person_ids = identities.distinct.pluck(:person_id)
          identities.delete_all
          person_ids.each do |person_id|
            person = Models::Person.find_by(id: person_id)
            next unless person
            next if Models::SourceIdentity.exists?(person_id: person_id)
            next if Models::RoleAssignment.exists?(person_id: person_id)
            next if Models::PersonMergeAudit.exists?(source_person_id: person_id) || Models::PersonMergeAudit.exists?(destination_person_id: person_id)

            person.delete
          end
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
