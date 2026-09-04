# frozen_string_literal: true

require "digest"
require "json"
require_relative "../ingestion/canonical_json"
require_relative "../metrics/comparison"
require_relative "../metrics/coverage"
require_relative "../metrics/report_cache"
require_relative "framework_coverage"
require_relative "report"

module Devdash
  module Reporting
    class ReportBuilder
      SECTION_ORDER = %w[speed ease quality thriving].freeze

      def initialize(registry:, cohort_resolver:, configuration: nil, coverage: Metrics::Coverage.new,
                     cache: Metrics::ReportCache.new, comparison: nil, clock: -> { Time.now.utc })
        @registry = registry
        @cohort_resolver = cohort_resolver
        @configuration = configuration
        @coverage = coverage
        @cache = cache
        @comparison = comparison
        @clock = clock
      end

      def call(owner:, window:, repository_scope:)
        owner = find_owner(owner)
        window = normalize_window(window)
        cohort = @cohort_resolver.call(owner:, at: window.end_at, repository_scope:)
        entries = metric_entries
        definitions = entries.map(&:definition)
        coverage_by_key = definitions.to_h do |definition|
          state = @coverage.call(definition:, window:, repository_scope:, at: window.end_at)
          [definition.key.to_s, coverage_hash(state)]
        end
        watermark = watermark_for(coverage_by_key)
        cohort_hash = cohort_hash_for(cohort)
        cached = @cache.fetch(window:, repository_scope:, cohort_hash:, metric_definitions: definitions,
          source_watermark_hash: watermark)
        if cached && cached.structured_json && !cached.rendered_text.to_s.empty?
          return Report.from_h(cached.structured).with(cached: true, cache_key: cached.cache_key)
        end

        rows = entries.map do |entry|
          definition = entry.definition
          current_owner = evaluate(entry, owner, window, repository_scope)
          previous_owner = evaluate(entry, owner, window.previous, repository_scope)
          peers = Array(cohort.included_ids).sort.map do |person_id|
            evaluate(entry, Models::Person.find(person_id), window, repository_scope)
          end
          current_owner = attach_coverage(current_owner, coverage_by_key.fetch(definition.key.to_s))
          comparison = build_comparison(definition:, owner:, owner_result: current_owner,
            peer_results: peers, previous_owner_result: previous_owner)
          metric_row(definition:, current_owner:, previous_owner:, peers:, comparison:,
            coverage: coverage_by_key.fetch(definition.key.to_s))
        end

        sections = SECTION_ORDER.to_h { |section| [section, rows.select { |row| row[:section] == section }] }
        freshness = freshness_for(coverage_by_key)
        partial_reasons = coverage_by_key.values.flat_map do |item|
          Array(item[:reasons] || item["reasons"])
        end.uniq.sort
        framework = FrameworkCoverage.new(definitions:, coverages: stringify_coverage(coverage_by_key)).call
        report = Report.new(
          owner:, reported_at: @clock.call.utc, window:, previous_window: window.previous,
          repository_scope:, cohort: cohort_hash_payload(cohort), sections:, coverage: coverage_by_key,
          freshness:, framework_coverage: framework, partial_data_reasons: partial_reasons,
          cache_key: nil, cached: false
        )
        rendered = TerminalRenderer.new.render(report)
        snapshot = @cache.write(window:, repository_scope:, cohort_hash:, metric_definitions: definitions,
          source_watermark_hash: watermark, structured: report.to_h, rendered_text: rendered)
        report.with(cache_key: snapshot.cache_key)
      end

      private

      def metric_entries
        entries = if @registry.respond_to?(:entries)
          @registry.entries
        elsif @registry.respond_to?(:each)
          @registry.each.to_a.map do |key, value|
            value.respond_to?(:definition) ? value : Struct.new(:definition, :query).new(value, value)
          end
        else
          Array(@registry)
        end
        entries.sort_by do |entry|
          definition = entry.definition
          [SECTION_ORDER.index(definition.engthrive_section.to_s) || 99,
            entry.respond_to?(:display_order) ? entry.display_order.to_i : 0, definition.key.to_s]
        end
      end

      def evaluate(entry, person, window, repository_scope)
        query = entry.respond_to?(:query) ? entry.query : entry
        result = query.respond_to?(:call) ? query.call(person:, window:, repository_scope:) : query.new.call(person:, window:, repository_scope:)
        result
      end

      def attach_coverage(result, coverage)
        return result unless result
        return result.with(coverage: coverage) if result.respond_to?(:with)
        return result.merge(coverage:) if result.respond_to?(:merge)

        result
      end

      def build_comparison(definition:, owner:, owner_result:, peer_results:, previous_owner_result:)
        return { status: "service_level_only", reason: "service-scoped metrics are not compared between people" } if service_metric?(definition)

        comparator = @comparison || Metrics::Comparison.new(definition:)
        result = comparator.call(owner_id: owner.id, owner_result:, peer_results:, previous_owner_result:)
        comparison_hash(result)
      end

      def metric_row(definition:, current_owner:, previous_owner:, peers:, comparison:, coverage:)
        {
          key: definition.key.to_s, name: definition.name.to_s, description: definition.description.to_s,
          unit: definition.unit.to_s, value_type: definition.value_type.to_s, signal_role: definition.signal_role.to_s,
          measurement_scope: definition.measurement_scope.to_s, directionality: definition.directionality.to_s,
          section: definition.engthrive_section.to_s, current: result_hash(current_owner),
          previous: result_hash(previous_owner), peers: peers.map { |result| result_hash(result) },
          comparison:, coverage:, breakdown: result_breakdown(current_owner),
          delta: comparison.is_a?(Hash) ? comparison[:absolute_delta] || comparison["absolute_delta"] : nil,
          owner_result: result_hash(current_owner), previous_result: result_hash(previous_owner),
          peer_distribution: comparison.is_a?(Hash) ? comparison[:statistics] || comparison["statistics"] : nil
        }
      end

      def result_hash(result)
        return {} unless result

        {
          person_id: result.respond_to?(:person_id) ? result.person_id : nil,
          value: result.respond_to?(:value) ? result.value : nil,
          sample_count: result.respond_to?(:sample_count) ? result.sample_count : nil,
          breakdown: result_breakdown(result), coverage: result.respond_to?(:coverage) ? result.coverage : nil,
          weekday_rate: result.respond_to?(:weekday_rate) ? result.weekday_rate : nil
        }
      end

      def result_breakdown(result)
        return {} unless result&.respond_to?(:breakdown)

        result.breakdown
      end

      def comparison_hash(value)
        return value unless value.respond_to?(:owner_result)

        {
          owner_percentile: value.owner_percentile, difference_from_median: value.difference_from_median,
          insufficient_peer_sample: value.insufficient_peer_sample, interpretation: value.interpretation,
          absolute_delta: value.absolute_delta, percent_delta: value.percent_delta,
          statistics: {
            n: value.statistics.n, median: value.statistics.median,
            p25: value.statistics.p25, p75: value.statistics.p75, iqr: value.statistics.iqr
          }
        }
      end

      def coverage_hash(state)
        return state.transform_keys(&:to_sym) if state.is_a?(Hash)

        {
          status: state&.status.to_s, reasons: Array(state&.reasons),
          affected_repositories: Array(state&.affected_repositories),
          last_success_timestamps: state&.last_success_timestamps || {},
          source_watermark_hash: state&.source_watermark_hash.to_s
        }
      end

      def freshness_for(coverages)
        coverages.each_with_object({}) do |(key, coverage), result|
          result[key] = coverage[:last_success_timestamps] || coverage["last_success_timestamps"] || {}
        end
      end

      def watermark_for(coverages)
        Digest::SHA256.hexdigest(Ingestion::CanonicalJson.dump(coverages.sort.to_h))
      end

      def cohort_hash_for(cohort)
        Digest::SHA256.hexdigest(Ingestion::CanonicalJson.dump(cohort_hash_payload(cohort)))
      end

      def cohort_hash_payload(cohort)
        included_ids = Array(cohort.included_ids).sort
        {
          included_ids:, sample_size: included_ids.length,
          sample_description: "#{included_ids.length} active same-role, same-level peer(s) with repository activity in the trailing 180d",
          exclusions: (cohort.exclusions || {}).sort.to_h,
          role: cohort.respond_to?(:role) ? cohort.role : nil,
          level: cohort.respond_to?(:level) ? cohort.level : nil
        }
      end

      def find_owner(owner)
        return owner if owner.respond_to?(:id)

        Models::Person.find(owner)
      end

      def normalize_window(window)
        return window if window.respond_to?(:start_at) && window.respond_to?(:end_at)

        Metrics::Window.for(window)
      end

      def service_metric?(definition)
        definition.measurement_scope.to_s == "service" ||
          Array(definition.framework_mappings).any? { |mapping| mapping_value(mapping, :framework).to_s == "dora" }
      end

      def mapping_value(mapping, key)
        return mapping.public_send(key) if mapping.respond_to?(key)
        return mapping[key] if mapping.respond_to?(:key?) && mapping.key?(key)
        return mapping[key.to_s] if mapping.respond_to?(:key?) && mapping.key?(key.to_s)

        nil
      end

      def stringify_coverage(coverages)
        coverages.transform_keys(&:to_s).transform_values do |coverage|
          coverage.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
        end
      end
    end
  end
end
