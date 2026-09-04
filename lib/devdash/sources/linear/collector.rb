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

        def initialize(client:, writer: Ingestion::Writer.new, clock: -> { Time.now.utc }, progress: nil)
          @client = client
          @writer = writer
          @clock = clock
          @progress = progress
          Linear.register_normalizer!
        end

        def call(since:)
          now = @clock.call
          report("linear/global: fetching issues")
          previous = Models::SyncCursor.find_by(source: "linear", scope_key: "global", cursor_type: "updated_at")
          cursor_before = previous&.cursor_value
          lower_bound = [since, (cursor_before && Time.iso8601(cursor_before) - OVERLAP)].compact.max
          issues = {}
          fetched_ids = {}
          relation_hydration_failures = []
          begin
            @client.each_issue(updated_since: lower_bound) do |issue|
              id = issue.fetch("id")
              fetched_ids[id] = true
              issues[id] = issue
              report("linear/global: fetched issue #{id} (#{issues.length})")
            end
          rescue Client::RelationHydrationError => error
            relation_hydration_failures << error
            report("linear/global: relation hydration failed for #{error.issue_id}")
          end
          report("linear/global: fetched #{issues.length} issues")
          missing_active_ids = []
          active_ids = Models::LinearIssue.where(active: true).pluck(:linear_id)
          report("linear/global: refreshing #{active_ids.length} active issues")
          active_ids.each_with_index do |id, index|
            report("linear/global: refreshing active issue #{id} (#{index + 1}/#{active_ids.length})")
            begin
              issue = @client.issue(id: id)
            rescue Client::RelationHydrationError => error
              relation_hydration_failures << error
              report("linear/global: relation hydration failed for #{error.issue_id}")
              issue = nil
            end
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
          issues.each_value.with_index do |issue, index|
            report("linear/global: fetching history for #{issue.fetch("id")} (#{index + 1}/#{issues.length})")
            observations << observation("linear_issue", issue.fetch("id"), issue, issue["updatedAt"], now, "issues")
            history = @client.issue_history(id: issue.fetch("id"))
            observations << observation("linear_issue_history", "#{issue.fetch("id")}:#{Digest::SHA256.hexdigest(Ingestion::CanonicalJson.dump(history))}",
              { "issue_id" => issue.fetch("id"), "history" => history }, issue["updatedAt"], now, "issue_history")
          end
          coverage_status = missing_active_ids.empty? && relation_hydration_failures.empty? ? "complete" : "partial"
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
          report("linear/global: writing #{observations.length} observations")
          run = @writer.call(batch)
          report("linear/global: finished (#{issues.length} issues)")
          run
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

        def report(message)
          @progress&.call(message)
        end
      end
    end
  end
end
