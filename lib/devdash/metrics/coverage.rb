# frozen_string_literal: true

require "digest"
require "json"
require_relative "../models/collector_run"
require_relative "../models/collector_run_coverage"
require_relative "../models/sync_cursor"

module Devdash
  module Metrics
    class Coverage
      State = Data.define(:status, :reasons, :affected_repositories, :last_success_timestamps, :source_watermark_hash) do
        def complete?
          status == "complete"
        end

        def partial?
          status == "partial"
        end

        def unavailable?
          status == "unavailable"
        end

        def watermark_hash
          source_watermark_hash
        end
      end

      def initialize(stale_after: 2 * 86_400, clock: -> { Time.now.utc })
        @stale_after = stale_after
        @clock = clock
      end

      def call(definition:, window:, repository_scope:, at: nil)
        at ||= @clock.call
        requirements = definition.required_coverage.map { |requirement| normalize_requirement(requirement) }
        reasons = []
        affected = []
        timestamps = {}
        successful_rows = []
        expected_count = 0
        complete_count = 0

        requirements.each do |requirement|
          expected_scopes(repository_scope, requirement).each do |expected|
            expected_count += 1
            rows = matching_rows(requirement, expected)
            latest = rows.max_by { |row| [row.achieved_end_at || Time.at(0), row.collector_run&.finished_at || Time.at(0), row.id] }
            label = expected == :global ? "global" : expected.to_s
            key = "#{requirement[:source]}/#{requirement[:entity_type]}/#{label}"
            if latest
              successful = rows.select { |row| row.status == "complete" }.max_by do |row|
                [row.achieved_end_at || Time.at(0), row.collector_run&.finished_at || Time.at(0), row.id]
              end
              if successful
                timestamps[key] = successful.collector_run&.finished_at || successful.achieved_end_at
                successful_rows << successful
              end
            end
            if complete_row?(latest, window, at)
              complete_count += 1
              next
            end

            if latest.nil?
              reasons << "missing coverage for #{key}"
              affected << label unless expected == :global
            elsif latest.status != "complete"
              reasons << "coverage not complete for #{key}"
              affected << label unless expected == :global
            elsif latest.achieved_start_at && latest.achieved_start_at > window.start_at
              reasons << "historical coverage begins after #{window.start_at.iso8601} for #{key}"
              affected << label unless expected == :global
            elsif stale?(latest, at)
              reasons << "stale coverage for #{key}"
              affected << label unless expected == :global
            else
              reasons << "coverage does not cover #{window.start_at.iso8601}..#{window.end_at.iso8601} for #{key}"
              affected << label unless expected == :global
            end
          end
        end

        status = if expected_count.zero? || complete_count == expected_count
          "complete"
        elsif complete_count.zero? && reasons.all? { |reason| reason.start_with?("missing coverage") }
          "unavailable"
        else
          "partial"
        end
        cursor_rows = relevant_cursors(requirements, repository_scope)
        watermark = Digest::SHA256.hexdigest(JSON.generate({
          "coverage" => successful_rows.sort_by(&:id).map do |row|
          [row.collector_run.source, row.scope_type, row.scope_key, row.entity_type,
           row.achieved_start_at&.utc&.iso8601(6), row.achieved_end_at&.utc&.iso8601(6),
           row.collector_run.finished_at&.utc&.iso8601(6)]
          end,
          "cursors" => cursor_rows.sort_by(&:id).map do |cursor|
            [cursor.source, cursor.scope_key, cursor.cursor_type, cursor.cursor_value, cursor.last_succeeded_at&.utc&.iso8601(6)]
          end
        }))
        State.new(status:, reasons: reasons.uniq.freeze, affected_repositories: affected.uniq.sort.freeze,
          last_success_timestamps: timestamps.freeze, source_watermark_hash: watermark)
      end

      private

      def normalize_requirement(requirement)
        if requirement.is_a?(Array)
          { source: requirement.fetch(0).to_s, entity_type: requirement.fetch(1).to_s, scope: "repository" }
        else
          requirement.transform_keys(&:to_sym).then do |value|
            value.merge(source: value.fetch(:source).to_s, entity_type: value.fetch(:entity_type).to_s,
              scope: value.fetch(:scope, "repository").to_s)
          end
        end
      end

      def expected_scopes(scope, requirement)
        return [:global] if requirement[:scope] == "global"
        names = scope.respond_to?(:repository_names) ? scope.repository_names : Array(scope)
        names.empty? ? [:global] : names
      end

      def matching_rows(requirement, expected)
        relation = Models::CollectorRunCoverage.joins(:collector_run).where(
          collector_runs: { source: requirement[:source] }, entity_type: requirement[:entity_type]
        )
        if expected == :global
          relation.where(scope_type: "global")
        else
          relation.where(scope_type: "repository", scope_key: expected.to_s)
        end.to_a
      end

      def complete_row?(row, window, at)
        row && row.status == "complete" && row.achieved_start_at && row.achieved_end_at &&
          row.achieved_start_at <= window.start_at && row.achieved_end_at >= window.end_at && !stale?(row, at)
      end

      def stale?(row, at)
        return false unless @stale_after
        finished_at = row.collector_run&.finished_at || row.achieved_end_at
        finished_at && (at - finished_at) > @stale_after
      end

      def relevant_cursors(requirements, scope)
        sources = requirements.map { |requirement| requirement[:source] }.uniq
        names = scope.respond_to?(:repository_names) ? scope.repository_names : Array(scope)
        global_sources = requirements.filter_map { |requirement| requirement[:source] if requirement[:scope] == "global" }.uniq
        relation = Models::SyncCursor.where(source: sources)
        return relation.to_a if names.empty?

        repository_cursors = relation.where(scope_key: names)
        global_cursors = global_sources.empty? ? relation.none : relation.where(source: global_sources)
        (repository_cursors.to_a + global_cursors.to_a).uniq(&:id)
      end
    end
  end
end
