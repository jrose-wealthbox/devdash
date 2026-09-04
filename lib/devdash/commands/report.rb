# frozen_string_literal: true

require "time"

module Devdash
  module Commands
    class Report < Base
      WINDOWS = %w[7d 30d 180d].freeze

      def initialize(configuration: nil, out: $stdout, err: $stderr, database: Devdash::Database,
                     clock: -> { Time.now.utc }, builder: nil, renderer: Reporting::TerminalRenderer.new,
                     identity: nil)
        super(configuration:, out:, err:, database:, clock:)
        @builder = builder
        @renderer = renderer
        @identity = identity
      end

      def call(window: "7d", repository_selector: nil, repo: nil, at: nil)
        window = window.to_s
        raise UsageError, "invalid window #{window.inspect}; expected 7d, 30d, or 180d" unless WINDOWS.include?(window)
        repository_selector ||= repo
        prepare_database!
        scope = repository_scope(repository_selector)
        config = @identity || identity_configuration(required: true)
        owner = owner_from_identity!(config)
        ending = parse_end_at(at || clock.call)
        report = (@builder || build_report_builder(config)).call(owner:, window: Metrics::Window.for(window, end_at: ending),
          repository_scope: scope)
        out.write(@renderer.render(report))
        0
      end

      private

      def build_report_builder(config)
        Reporting::ReportBuilder.new(registry: metric_registry,
          cohort_resolver: Identity::CohortResolver.new(configuration: config), configuration: load_configuration)
      end

      def parse_end_at(value)
        return value if value.respond_to?(:utc)

        Time.iso8601(value.to_s).utc
      rescue ArgumentError, TypeError
        raise UsageError, "--at must be an ISO8601 timestamp"
      end
    end
  end
end
