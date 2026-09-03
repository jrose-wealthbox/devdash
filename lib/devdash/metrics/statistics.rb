# frozen_string_literal: true

module Devdash
  module Metrics
    module Statistics
      Summary = Data.define(:n, :median, :p25, :p75, :iqr) do
        def empty?
          n.zero?
        end

        alias sample_count n
      end
      module_function

      # Quantiles use linear interpolation over the inclusive [0, n - 1]
      # index range. Thus p50([1, 2, 3, 4]) is 2.5 and p25 is 1.75.
      def call(values)
        observations = Array(values).compact.map(&:to_f).sort
        return Summary.new(n: 0, median: nil, p25: nil, p75: nil, iqr: nil) if observations.empty?

        p25 = quantile(observations, 0.25)
        p75 = quantile(observations, 0.75)
        Summary.new(n: observations.length, median: quantile(observations, 0.5), p25:, p75:, iqr: p75 - p25)
      end

      def quantile(values, probability)
        observations = Array(values).compact.map(&:to_f).sort
        return nil if observations.empty?
        return observations.first if observations.length == 1

        position = (observations.length - 1) * probability.to_f
        lower = observations[position.floor]
        upper = observations[position.ceil]
        lower + ((upper - lower) * (position - position.floor))
      end
    end
  end
end
