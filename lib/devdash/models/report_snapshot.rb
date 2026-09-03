# frozen_string_literal: true

require "json"

module Devdash
  module Models
    class ReportSnapshot < BaseRecord
      self.record_timestamps = false

      # Rails reserves `cache_key` for model cache identity. This table uses
      # the name deliberately for the semantic report key, so opt that one
      # attribute out of Active Record's dangerous-method guard.
      def self.dangerous_attribute_method?(name)
        return false if name.to_s == "cache_key"

        super
      end

      validates :cache_key, :window_start_at, :window_end_at, :repository_scope_hash,
        :cohort_hash, :metric_versions_hash, :source_watermark_hash, :format_version,
        :structured_json, presence: true
      validates :format_version, numericality: { only_integer: true, greater_than: 0 }
      validates :cache_key, uniqueness: true

      def structured
        JSON.parse(structured_json)
      end
    end
  end
end
