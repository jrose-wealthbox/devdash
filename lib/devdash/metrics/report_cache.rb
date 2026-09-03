# frozen_string_literal: true

require "digest"
require "json"
require_relative "../ingestion/canonical_json"
require_relative "../models/report_snapshot"

module Devdash
  module Metrics
    class ReportCache
      attr_reader :format_version

      def initialize(format_version: 1)
        @format_version = Integer(format_version)
      end

      def key_for(window:, repository_scope:, cohort_hash:, metric_definitions:, source_watermark_hash:)
        Digest::SHA256.hexdigest(Devdash::Ingestion::CanonicalJson.dump(semantic_payload(
          window:, repository_scope:, cohort_hash:, metric_definitions:, source_watermark_hash:
        )))
      end

      alias cache_key_for key_for

      def fetch(window:, repository_scope:, cohort_hash:, metric_definitions:, source_watermark_hash:)
        Models::ReportSnapshot.find_by(cache_key: key_for(window:, repository_scope:, cohort_hash:, metric_definitions:, source_watermark_hash:))
      end

      def write(window:, repository_scope:, cohort_hash:, metric_definitions:, source_watermark_hash:, structured:, rendered_text: nil)
        cache_key = key_for(window:, repository_scope:, cohort_hash:, metric_definitions:, source_watermark_hash:)
        metric_versions_hash = hash_metric_versions(metric_definitions)
        attributes = {
          cache_key:, window_start_at: window.start_at, window_end_at: window.end_at,
          repository_scope_hash: repository_scope.configuration_hash.to_s, cohort_hash: cohort_hash.to_s,
          metric_versions_hash:, source_watermark_hash: source_watermark_hash.to_s,
          format_version:, structured_json: Devdash::Ingestion::CanonicalJson.dump(structured), rendered_text:
        }
        Models::ReportSnapshot.create_or_find_by!(cache_key:) do |snapshot|
          snapshot.assign_attributes(attributes)
        end
      end

      def clear!
        Models::ReportSnapshot.delete_all
      end

      private

      def semantic_payload(window:, repository_scope:, cohort_hash:, metric_definitions:, source_watermark_hash:)
        {
          "window" => { "key" => window.key.to_s, "start_at" => window.start_at.utc.iso8601(6), "end_at" => window.end_at.utc.iso8601(6) },
          "repository_scope_hash" => repository_scope.configuration_hash.to_s,
          "repository_names" => Array(repository_scope.repository_names).map(&:to_s).sort,
          "cohort_hash" => cohort_hash.to_s,
          "metric_versions" => Array(metric_definitions).map { |definition| metric_key_version(definition) }.sort_by { |item| [item["key"], item["version"]] },
          "source_watermark_hash" => source_watermark_hash.to_s,
          "format_version" => format_version
        }
      end

      def metric_key_version(definition)
        if definition.respond_to?(:key) && definition.respond_to?(:version)
          { "key" => definition.key.to_s, "version" => definition.version.to_i }
        else
          hash = definition.transform_keys(&:to_sym)
          { "key" => hash.fetch(:key).to_s, "version" => hash.fetch(:version).to_i }
        end
      end

      def hash_metric_versions(definitions)
        Digest::SHA256.hexdigest(Devdash::Ingestion::CanonicalJson.dump(Array(definitions).map { |definition| metric_key_version(definition) }.sort_by { |item| [item["key"], item["version"]] }))
      end
    end
  end
end
