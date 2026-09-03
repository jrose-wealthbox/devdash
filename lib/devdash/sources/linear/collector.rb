# frozen_string_literal: true

require "time"
require "digest"
require_relative "../../../devdash"
require_relative "../../ingestion/batch"
require_relative "../../ingestion/source_observation"
require_relative "../../ingestion/canonical_json"
require_relative "../../ingestion/writer"
require_relative "../../models/linear_issue"
require_relative "normalizer"
require_relative "client"

module Devdash
  module Sources
    module Linear
      class Collector
        OVERLAP = 48 * 60 * 60

        def initialize(client:, writer: Ingestion::Writer.new, clock: -> { Time.now.utc })
          @client = client
          @writer = writer
          @clock = clock
          Linear.register_normalizer!
        end

        def call(since:)
          now = @clock.call
          previous = Models::SyncCursor.find_by(source: "linear", scope_key: "global", cursor_type: "updated_at")
          cursor_before = previous&.cursor_value
          lower_bound = [since, (cursor_before && Time.iso8601(cursor_before) - OVERLAP)].compact.max
          issues = {}
          fetched_ids = {}
          @client.each_issue(updated_since: lower_bound) do |issue|
            id = issue.fetch("id")
            fetched_ids[id] = true
            issues[id] = issue
          end
          missing_active_ids = []
          Models::LinearIssue.where(active: true).pluck(:linear_id).each do |id|
            issue = @client.issue(id: id)
            if issue
              fetched_ids[id] = true
              issues[id] = issue
            else
              # A local active issue that could not be refreshed is not
              # evidence that its history was covered by this run.
              missing_active_ids << id unless fetched_ids[id]
            end
          end

          observations = []
          issues.each_value do |issue|
            observations << observation("linear_issue", issue.fetch("id"), issue, issue["updatedAt"], now, "issues")
            history = @client.issue_history(id: issue.fetch("id"))
            observations << observation("linear_issue_history", "#{issue.fetch("id")}:#{Digest::SHA256.hexdigest(Ingestion::CanonicalJson.dump(history))}",
              { "issue_id" => issue.fetch("id"), "history" => history }, issue["updatedAt"], now, "issue_history")
          end
          coverage_status = missing_active_ids.empty? ? "complete" : "partial"
          cursor_after = coverage_status == "complete" ? next_cursor(cursor_before, issues.values, now) : cursor_before
          achieved_end_at = coverage_status == "complete" ? now : nil
          batch = Ingestion::Batch.new(source: "linear", scope_key: "global", cursor_type: "updated_at",
            cursor_before:, cursor_after:, observations:, page_count: issues.length, retry_count: 0,
            coverages: [
              { scope_type: "global", scope_key: "global", entity_type: "linear_issue", requested_start_at: lower_bound,
                requested_end_at: now, achieved_start_at: lower_bound, achieved_end_at:, status: coverage_status },
              { scope_type: "global", scope_key: "global", entity_type: "linear_issue_history", requested_start_at: lower_bound,
                requested_end_at: now, achieved_start_at: lower_bound, achieved_end_at:, status: coverage_status }
            ])
          @writer.call(batch)
        end

        private

        def observation(entity_type, external_id, payload, updated_at, observed_at, fingerprint)
          Ingestion::SourceObservation.new(entity_type:, external_id:, source_updated_at: parse_time(updated_at), observed_at:,
            api_version: "linear-graphql", query_fingerprint: fingerprint, payload:)
        end

        def parse_time(value)
          Time.iso8601(value).utc if value
        rescue ArgumentError
          nil
        end

        def next_cursor(cursor_before, issues, successful_observation_boundary)
          timestamps = [parse_time(cursor_before), successful_observation_boundary]
          timestamps.concat(issues.filter_map { |issue| parse_time(issue["updatedAt"]) })
          timestamps.compact.max.utc.iso8601
        end
      end
    end
  end
end
