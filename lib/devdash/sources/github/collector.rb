# frozen_string_literal: true

require "time"

module Devdash
  class Error < StandardError; end unless const_defined?(:Error, false)
end

require_relative "../../ingestion/batch"
require_relative "../../ingestion/source_observation"
require_relative "../../ingestion/writer"
require_relative "normalizer"
require_relative "../../models/collector_run"
require_relative "../../models/collector_run_coverage"
require_relative "../../models/source_record"
require_relative "../../models/sync_cursor"
require_relative "client"

module Devdash
  module Sources
    module Github
      class Collector
        SOURCE = "github"
        CURSOR_TYPE = "updated_at"
        DEFAULT_OVERLAP = 48 * 3600

        def initialize(client: Client.new, writer: Devdash::Ingestion::Writer.new,
                       clock: -> { Time.now.utc }, overlap: DEFAULT_OVERLAP)
          @client, @writer, @clock, @overlap = client, writer, clock, overlap
        end

        def call(repository_scope:, since:)
          Github.register_normalizer!
          repository_scope.repository_names.each_with_object([]) do |name, runs|
            runs << collect_repository(name, since)
          end
        end

        private

        def collect_repository(name, requested_since)
          @client.reset_page_count! if @client.respond_to?(:reset_page_count!)
          repository = @client.repository(name)
          observed_at = @clock.call.utc
          cursor = Models::SyncCursor.find_by(source: SOURCE, scope_key: name, cursor_type: CURSOR_TYPE)
          cursor_before = cursor&.cursor_value
          from = lower_bound(requested_since, cursor_before, observed_at)

          numbers = (@client.updated_pull_numbers(name, from:, to: observed_at) + @client.open_pull_numbers(name)).uniq.sort
          observations = [observation("repository", "github:#{name}:repository", repository, observed_at, source_time(repository["updated_at"]))]

          numbers.each do |number|
            pull = @client.pull(name, number)
            pull_updated_at = source_time(pull["updated_at"])
            observations << observation("pull_request", "github:#{name}:pull:#{number}", pull, observed_at, pull_updated_at)

            reviews = @client.reviews(name, number).map { |item| item.merge("_pull_number" => number) }
            observations << observation("pull_request_reviews", "github:#{name}:pull_reviews:#{number}", reviews, observed_at,
              latest_source_time(reviews, "submitted_at") || pull_updated_at)

            timeline = @client.timeline(name, number).map { |item| item.merge("_pull_number" => number) }
            observations << observation("pull_request_timeline", "github:#{name}:pull_event:#{number}", timeline, observed_at,
              latest_source_time(timeline, "created_at") || pull_updated_at)

            files = @client.pull_files(name, number).map { |item| item.merge("_pull_number" => number) }
            observations << observation("pull_request_files", "github:#{name}:pull_files:#{number}", files, observed_at, pull_updated_at)
          end

          branch = repository["default_branch"] || "main"
          @client.default_branch_commits(name, branch:, since: from).each do |summary|
            sha = summary.fetch("sha")
            detail = @client.commit_detail(name, sha).merge("default_branch_reachable" => true)
            source_updated_at = source_time(detail.dig("commit", "committer", "date")) ||
              source_time(detail.dig("commit", "author", "date")) ||
              source_time(summary.dig("commit", "committer", "date"))
            observations << observation("commit_files", "github:#{name}:commit:#{sha}", detail, observed_at, source_updated_at)
          end

          batch = Devdash::Ingestion::Batch.new(
            source: SOURCE, scope_key: name, cursor_type: CURSOR_TYPE,
            cursor_before:, cursor_after: next_cursor(cursor_before, observations, observed_at),
            observations:, coverages: coverages(name, from, observed_at),
            page_count: page_count, retry_count: 0
          )
          @writer.call(batch)
        end

        def lower_bound(requested_since, cursor_before, observed_at)
          cursor_time = source_time(cursor_before)
          requested_time = source_time(requested_since)
          candidate = [requested_time, cursor_time && cursor_time - @overlap].compact.max
          candidate ||= observed_at - @overlap
          [candidate, observed_at].compact.min
        end

        def coverages(name, from, observed_at)
          %w[repository pull_requests pull_request_reviews pull_request_events pull_request_files commits commit_files].map do |entity_type|
            {
              scope_type: "repository", scope_key: name, entity_type: entity_type,
              requested_start_at: from, requested_end_at: observed_at,
              achieved_start_at: from, achieved_end_at: observed_at, status: "complete"
            }
          end
        end

        def next_cursor(cursor_before, observations, observed_at)
          previous = source_time(cursor_before)
          source_max = observations.filter_map(&:source_updated_at).max || observed_at
          [previous, source_max].compact.max.iso8601
        end

        def page_count
          @client.respond_to?(:page_count) ? @client.page_count.to_i : 0
        end

        def observation(entity_type, external_id, payload, observed_at, source_updated_at)
          Devdash::Ingestion::SourceObservation.new(
            entity_type:, external_id:, source_updated_at:, observed_at:,
            api_version: "github", query_fingerprint: "github:#{entity_type}", payload:
          )
        end

        def latest_source_time(items, key)
          Array(items).filter_map { |item| source_time(item[key]) }.max
        end

        def source_time(value)
          return value.utc if value.respond_to?(:utc)
          return if value.to_s.empty?

          Time.iso8601(value.to_s).utc
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end

Devdash::Sources::GitHub = Devdash::Sources::Github unless Devdash::Sources.const_defined?(:GitHub, false)
