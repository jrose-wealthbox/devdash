# frozen_string_literal: true

module Devdash
  module Commands
    class Reprocess < Base
      def initialize(configuration: nil, out: $stdout, err: $stderr, database: Devdash::Database,
                     clock: -> { Time.now.utc }, reprocessor: nil, cache: nil)
        super(configuration:, out:, err:, database:, clock:)
        @reprocessor = reprocessor
        @cache = cache
      end

      def call
        prepare_database!
        Devdash.register_source_normalizers!
        registry = metric_registry
        @reprocessor ||= Reprocessing::Reprocessor.new(registry: Normalizers::Registry, derived_rebuilder: nil)
        result = @reprocessor.call
        config = identity_configuration
        if config
          Identity::Resolver.new(configuration: config, clock:).call
          Identity::IssueRepositoryResolver.new(configuration: config).call
        end
        clear_report_cache!
        out.puts "Reprocessed #{Array(result).length} normalizer group(s)." unless result.nil?
        0
      end

      private

      def clear_report_cache!
        return @cache.clear! if @cache
        return unless ActiveRecord::Base.connected?

        Metrics::ReportCache.new.clear!
      end
    end
  end
end
