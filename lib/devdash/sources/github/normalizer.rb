# frozen_string_literal: true

require "json"
require "set"

module Devdash
  module Sources
    module Github
      class Normalizer
        VERSION = 1
        attr_reader :version
        def initialize(exclusion_globs: ["**/vendor/**", "vendor/**", "**/generated/**", "generated/**", "**/*.lock", "*.lock"])
          @version = VERSION
          @exclusion_globs = exclusion_globs
        end

        def call(record)
          payload = JSON.parse(record.payload_json)
          case record.entity_type
          when "repository" then normalize_repository(record.scope_key, payload)
          when "pull_request" then normalize_pull(record.scope_key, payload)
          when "pull_request_reviews" then normalize_reviews(record.scope_key, payload)
          when "pull_request_timeline" then normalize_events(record.scope_key, payload)
          when "pull_request_files" then normalize_files(record.scope_key, payload)
          when "commit" then normalize_commit(record.scope_key, payload)
          when "commit_files" then normalize_commit_files(record.scope_key, payload)
          end
        end

        def reset!
          Models::PullRequestFile.delete_all
          Models::PullRequestReview.delete_all
          Models::PullRequestEvent.delete_all
          Models::CommitFile.delete_all
          Models::Commit.delete_all
          Models::PullRequest.delete_all
          Models::SourceIdentity.where(source: "github").delete_all
        end

        private

        def repository(name)
          Models::Repository.find_or_create_by!(full_name: name) { |r| r.alias_name = name.split("/").last }
        end

        def person(login, email: nil)
          return nil if login.to_s.empty? && email.to_s.empty?
          external = login.to_s.empty? ? email.to_s : login.to_s
          identity = Models::SourceIdentity.find_by(source: "github", external_id: external)
          return identity.person if identity
          p = Models::Person.create!(display_name: login.to_s.empty? ? email : login)
          Models::SourceIdentity.create!(person: p, source: "github", external_id: external, login: login, normalized_email: email, observed_display_name: login)
          p
        end

        def normalize_repository(name, payload)
          repo = repository(name)
          repo.update!(external_id: payload["node_id"], default_branch: payload.dig("default_branch"), archived: payload["archived"] == true, metadata_json: JSON.generate(payload))
        end

        def normalize_pull(name, p)
          repo = repository(name)
          pr = Models::PullRequest.find_or_initialize_by(repository: repo, number: p.fetch("number"))
          user = p["user"] || {}
          pr.update!(node_id: p["node_id"], author: person(user["login"], email: nil), author_login: user["login"], state: p["state"], draft: p["draft"] == true, base_branch: p.dig("base", "ref"), head_sha: p.dig("head", "sha"), merge_sha: p["merge_commit_sha"], opened_at: parse_time(p["created_at"]), closed_at: parse_time(p["closed_at"]), merged_at: parse_time(p["merged_at"]), source_updated_at: parse_time(p["updated_at"]), additions: p["additions"], deletions: p["deletions"], changed_files_count: p["changed_files"])
        end

        def pull(name, number) = Models::PullRequest.find_by!(repository: repository(name), number: number)

        def normalize_reviews(name, list)
          Array(list).uniq { |r| r["id"].to_s }.each do |r|
            pr = pull(name, r["_pull_number"] || r.fetch("pull_request_url").split("/").last.to_i)
            u = r["user"] || {}
            Models::PullRequestReview.find_or_initialize_by(github_review_id: r.fetch("id").to_s).update!(pull_request: pr, reviewer: person(u["login"]), reviewer_login: u["login"], state: r["state"], submitted_at: parse_time(r["submitted_at"]))
          end
        end

        def normalize_events(name, list)
          Array(list).each do |event|
            next unless event["id"]
            pr = pull(name, event["_pull_number"] || event.fetch("issue", {})["number"] || event["number"])
            actor = event["actor"] || event["user"] || {}
            requested = event["requested_reviewer"] || event["requested_team"] || {}
            Models::PullRequestEvent.find_or_initialize_by(pull_request: pr, stable_external_id: event["id"].to_s).update!(kind: event["event"] || event["type"], actor: person(actor["login"]), actor_login: actor["login"], subject: person(requested["login"]), subject_login: requested["login"], occurred_at: parse_time(event["created_at"]), derivation: "github_timeline")
          end
        end

        def normalize_files(name, list)
          list = Array(list)
          return if list.empty?
          number = list.first["_pull_number"] || list.first.dig("pull_request", "number")
          return unless number
          pr = pull(name, number)
          pr.pull_request_files.delete_all
          list.each { |f| pr.pull_request_files.create!(path: f.fetch("filename"), status: f["status"], additions: f["additions"] || 0, deletions: f["deletions"] || 0, exclusion_category: exclusion(f.fetch("filename"))) }
        end

        def normalize_commit(name, c)
          repo = repository(name)
          a, comm = c.dig("commit", "author") || {}, c.dig("commit", "committer") || {}
          Models::Commit.find_or_initialize_by(repository: repo, sha: c.fetch("sha")).update!(author: person(c.dig("author", "login"), email: a["email"]), committer: person(c.dig("committer", "login"), email: comm["email"]), author_login: c.dig("author", "login"), author_email: a["email"], committer_login: c.dig("committer", "login"), committer_email: comm["email"], authored_at: parse_time(a["date"]), committed_at: parse_time(comm["date"]), parent_count: Array(c["parents"]).length, default_branch_reachable: c["default_branch_reachable"] == true)
        end

        def normalize_commit_files(name, payload)
          c = normalize_commit(name, payload)
          commit = Models::Commit.find_by!(repository: repository(name), sha: payload.fetch("sha"))
          commit.commit_files.delete_all
          Array(payload["files"]).each { |f| commit.commit_files.create!(path: f.fetch("filename"), status: f["status"], additions: f["additions"] || 0, deletions: f["deletions"] || 0, exclusion_category: exclusion(f.fetch("filename"))) }
        end

        def exclusion(path)
          return "lockfile" if path.end_with?(".lock")
          return "vendor" if path.start_with?("vendor/") || path.include?("/vendor/")
          return "generated" if path.start_with?("generated/") || path.include?("/generated/")
          nil
        end

        def parse_time(value)
          Time.iso8601(value).utc if value
        rescue ArgumentError
          nil
        end
      end
    end
  end
end

Devdash::Sources::GitHub = Devdash::Sources::Github unless Devdash::Sources.const_defined?(:GitHub, false)

Devdash::Normalizers::Registry.register(source: "github", entity_type: "repository", normalizer: Devdash::Sources::Github::Normalizer.new)
%w[pull_request pull_request_reviews pull_request_timeline pull_request_files commit commit_files].each do |type|
  Devdash::Normalizers::Registry.register(source: "github", entity_type: type, normalizer: Devdash::Sources::Github::Normalizer.new)
end
