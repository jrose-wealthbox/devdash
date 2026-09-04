# frozen_string_literal: true

module Devdash
  module Commands
    class Backfill < Sync
      SAFETY_MARGIN_DAYS = 2

      def initialize(**options)
        super(**options)
      end

      def call(days:, repository_selector: nil, repo: nil)
        days = Integer(days)
      rescue ArgumentError, TypeError
        raise UsageError, "--days must be a positive integer"
      else
        raise UsageError, "--days must be a positive integer" unless days.positive?
        repository_selector ||= repo
        prepare_database!
        scope = repository_scope(repository_selector)
        github_collector.call(repository_scope: scope, since: clock.call.utc - ((days + SAFETY_MARGIN_DAYS) * 86_400))
        linear_collector.call(since: clock.call.utc - ((days + SAFETY_MARGIN_DAYS) * 86_400))
        resolve_identity_and_links
        0
      end
    end
  end
end
