# frozen_string_literal: true

require "time"

module Devdash
  module Sources
    module Github
      class Collector
        def initialize(client: Client.new, writer: Devdash::Ingestion::Writer.new, clock: -> { Time.now.utc }, overlap: 48 * 3600)
          @client, @writer, @clock, @overlap = client, writer, clock, overlap
        end

        def call(repository_scope:, since:)
          repository_scope.repository_names.each_with_object([]) do |name, runs|
            runs << collect_repository(name, since)
          end
        end

        private

        def collect_repository(name, since)
          repo = @client.repository(name)
          end_at = @clock.call
          from = since || (end_at - @overlap)
          numbers = (@client.updated_pull_numbers(name, from: from, to: end_at) + @client.open_pull_numbers(name)).uniq
          observations = [observation("repository", name, repo, end_at)]
          numbers.each do |number|
            pull = @client.pull(name, number)
            observations << observation("pull_request", "github:#{name}:pull:#{number}", pull, end_at)
            reviews = @client.reviews(name, number).each { |item| item["_pull_number"] = number }
            timeline = @client.timeline(name, number).each { |item| item["_pull_number"] = number }
            observations << observation("pull_request_reviews", "github:#{name}:pull_reviews:#{number}", reviews, end_at)
            observations << observation("pull_request_timeline", "github:#{name}:pull_event:#{number}", timeline, end_at)
            files = @client.pull_files(name, number)
            files.each { |file| file["_pull_number"] = number }
            observations << observation("pull_request_files", "github:#{name}:pull_files:#{number}", files, end_at)
          end
          branch = repo["default_branch"] || "main"
          @client.default_branch_commits(name, branch: branch, since: from).each do |summary|
            sha = summary.fetch("sha")
            detail = @client.commit_detail(name, sha).merge("default_branch_reachable" => true)
            observations << observation("commit_files", "github:#{name}:commit:#{sha}", detail, end_at)
          end
          batch = Devdash::Ingestion::Batch.new(source: "github", scope_key: name, cursor_type: "updated_at", cursor_before: nil, cursor_after: end_at.iso8601, observations:, coverages: [{ entity_type: "pull_requests", requested_start_at: from, requested_end_at: end_at, achieved_start_at: from, achieved_end_at: end_at, status: "complete" }], page_count: 0, retry_count: 0)
          @writer.call(batch)
        end

        def observation(type, id, payload, at)
          Devdash::Ingestion::SourceObservation.new(entity_type: type, external_id: id, source_updated_at: at, observed_at: at, api_version: "github", query_fingerprint: "github:#{type}", payload: payload)
        end
      end
    end
  end
end
