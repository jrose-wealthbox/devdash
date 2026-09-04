# frozen_string_literal: true

module Devdash
  module Commands
    class RebuildDerived < Base
      def initialize(configuration: nil, out: $stdout, err: $stderr, database: Devdash::Database,
                     clock: -> { Time.now.utc }, cache: nil)
        super(configuration:, out:, err:, database:, clock:)
        @cache = cache
      end

      def call
        prepare_database!
        (@cache || Metrics::ReportCache.new).clear!
        out.puts "Cleared report snapshots."
        0
      end
    end
  end
end
