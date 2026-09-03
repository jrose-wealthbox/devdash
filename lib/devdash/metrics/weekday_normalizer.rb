# frozen_string_literal: true

require "date"

module Devdash
  module Metrics
    module WeekdayNormalizer
      SECONDS_PER_DAY = 86_400.0
      module_function

      def call(window)
        equivalent_days(window)
      end

      def equivalent_days(window)
        start_at = window.start_at.utc
        end_at = window.end_at.utc
        return nil if end_at <= start_at

        total_seconds = 0.0
        day = start_at.to_date
        while day.to_time(:utc) < end_at
          day_start = day.to_time(:utc)
          day_end = day_start + SECONDS_PER_DAY
          if (1..5).cover?(day.cwday)
            total_seconds += [end_at, day_end].min - [start_at, day_start].max
          end
          day += 1
        end
        total_seconds / SECONDS_PER_DAY
      end
    end
  end
end
