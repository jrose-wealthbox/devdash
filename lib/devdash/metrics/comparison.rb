# frozen_string_literal: true

require_relative "result"
require_relative "statistics"

module Devdash
  module Metrics
    class Comparison
      ComparisonResult = Data.define(
        :owner_result, :peer_results, :statistics, :owner_percentile,
        :difference_from_median, :insufficient_peer_sample, :interpretation,
        :previous_owner_result, :absolute_delta, :percent_delta
      ) do
        def owner
          owner_result
        end

        def peers
          peer_results
        end

        def delta
          absolute_delta
        end

        def n
          statistics.n
        end

        def peer_sample_size
          statistics.n
        end

        def median
          statistics.median
        end

        def p25
          statistics.p25
        end

        def p75
          statistics.p75
        end

        def iqr
          statistics.iqr
        end

        alias percentile owner_percentile
      end

      def initialize(definition: nil)
        @definition = definition
      end

      def call(owner_id:, owner_result: nil, peer_results: nil, previous_owner_result: nil,
               results: nil, previous_results: nil, owner: nil, peers: nil, **_options)
        owner_result ||= owner
        peer_results ||= peers
        if results
          owner_result ||= Array(results).find { |result| result.person_id == owner_id }
          peer_results ||= Array(results).reject { |result| result.person_id == owner_id }
        end
        if previous_results && previous_owner_result.nil?
          previous_owner_result = Array(previous_results).find { |result| result.person_id == owner_id }
        end
        raise ArgumentError, "owner result is required" unless owner_result

        definition = @definition || owner_result.definition
        owner_result = aggregate(owner_id, Array(owner_result), definition)
        peer_groups = Array(peer_results).group_by(&:person_id)
        peer_results = peer_groups.keys.sort.map { |person_id| aggregate(person_id, peer_groups.fetch(person_id), definition) }
        previous_owner_result = aggregate(owner_id, Array(previous_owner_result), definition) if previous_owner_result

        observations = peer_results.filter_map(&:value)
        statistics = Statistics.call(observations)
        insufficient = statistics.n < 3
        percentile = if insufficient || directionless?(definition) || owner_result.value.nil?
          nil
        else
          percentile_rank(owner_result.value.to_f, observations, definition.directionality)
        end
        difference = if owner_result.value.nil? || statistics.median.nil?
          nil
        else
          owner_result.value.to_f - statistics.median
        end
        absolute_delta, percent_delta = deltas(owner_result.value, previous_owner_result&.value)

        ComparisonResult.new(
          owner_result:, peer_results: peer_results.freeze, statistics:, owner_percentile: percentile,
          difference_from_median: difference, insufficient_peer_sample: insufficient,
          interpretation: interpretation(percentile, definition, insufficient),
          previous_owner_result:, absolute_delta:, percent_delta:
        )
      end

      private

      def aggregate(person_id, results, definition)
        return results.first if results.length <= 1

        first = results.first
        values = results.filter_map(&:value)
        value = if definition.value_type.to_s == "duration"
          samples = results.flat_map(&:samples)
          samples.empty? ? nil : Statistics.quantile(samples, 0.5)
        else
          values.empty? ? nil : values.sum(&:to_f)
        end
        sample_count = if definition.value_type.to_s == "duration"
          results.flat_map(&:samples).length
        else
          results.sum(&:sample_count)
        end
        breakdown = if definition.value_type.to_s == "duration"
          { samples: results.flat_map(&:samples) }
        else
          { repository_values: results.to_h { |result| [result.repository_scope&.key, result.value] } }
        end
        Result.new(definition:, person_id:, window: first.window, repository_scope: first.repository_scope,
          value:, sample_count:, breakdown:, coverage: combine_coverage(results))
      end

      def combine_coverage(results)
        coverages = results.map(&:coverage).compact
        return nil if coverages.empty?
        return coverages.first if coverages.map(&:to_h).uniq.length == 1

        coverages.min_by { |coverage| { "unavailable" => 0, "partial" => 1, "complete" => 2 }.fetch(coverage.status.to_s, 0) }
      end

      def directionless?(definition)
        definition.directionality.to_s == "directionless"
      end

      def percentile_rank(owner, observations, directionality)
        return nil if observations.empty?
        rank = if directionality.to_s == "lower_better"
          observations.count { |value| value.to_f >= owner }
        else
          observations.count { |value| value.to_f <= owner }
        end
        (rank.to_f / observations.length) * 100.0
      end

      def interpretation(percentile, definition, insufficient)
        return nil if percentile.nil? || insufficient || directionless?(definition)
        percentile >= 75 ? "favorable" : (percentile <= 25 ? "unfavorable" : "neutral")
      end

      def deltas(current, previous)
        return [nil, nil] if current.nil? || previous.nil?
        absolute = current.to_f - previous.to_f
        percent = previous.to_f.zero? ? nil : (absolute / previous.to_f) * 100.0
        [absolute, percent]
      end
    end
  end
end
