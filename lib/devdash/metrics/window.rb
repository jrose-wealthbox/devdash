# frozen_string_literal: true

require "time"

module Devdash
  module Metrics
    Window = Data.define(:key, :start_at, :end_at) do
      SUPPORTED_DURATIONS = { "7d" => 7 * 86_400, "30d" => 30 * 86_400, "180d" => 180 * 86_400 }.freeze

      class << self
        def for(key, end_at: Time.now.utc)
          key = key.to_s
          duration = SUPPORTED_DURATIONS.fetch(key) do
            raise ArgumentError, "unsupported window #{key.inspect}; expected 7d, 30d, or 180d"
          end
          ending = utc_time(end_at)
          new(key:, start_at: ending - duration, end_at: ending)
        end

        private

        def utc_time(value)
          value.respond_to?(:utc) ? value.utc : Time.parse(value.to_s).utc
        rescue ArgumentError
          raise ArgumentError, "end_at must be a timestamp"
        end
      end

      def duration
        end_at - start_at
      end

      def previous
        self.class.new(key:, start_at: start_at - duration, end_at: start_at)
      end

      def include?(timestamp)
        timestamp = timestamp.respond_to?(:utc) ? timestamp.utc : Time.parse(timestamp.to_s).utc
        timestamp >= start_at && timestamp < end_at
      end

      def empty?
        end_at <= start_at
      end
    end
  end
end
