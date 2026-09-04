# frozen_string_literal: true

require "pathname"
require "digest"
require "json"

module Devdash
  class Error < StandardError; end
  class ConfigurationError < Error; end

  def self.root
    @root ||= Pathname(__dir__).join("..").expand_path
  end
end

require_relative "devdash/repository_scope"
require_relative "devdash/configuration"
require_relative "devdash/database"
require_relative "devdash/models/base_record"
require_relative "devdash/models/organization"
require_relative "devdash/models/person"
require_relative "devdash/models/person_merge_audit"
require_relative "devdash/models/source_identity"
require_relative "devdash/models/role_assignment"
require_relative "devdash/models/repository"
require_relative "devdash/models/collector_run"
require_relative "devdash/models/collector_run_coverage"
require_relative "devdash/models/sync_cursor"
require_relative "devdash/models/source_record"
require_relative "devdash/models/normalization_run"
require_relative "devdash/ingestion/canonical_json"
require_relative "devdash/ingestion/source_observation"
require_relative "devdash/ingestion/batch"
require_relative "devdash/normalizers/registry"
require_relative "devdash/ingestion/writer"
require_relative "devdash/transports/errors"
require_relative "devdash/transports/command"
require_relative "devdash/transports/http_json"
require_relative "devdash/reprocessing/derived_rebuilder"
require_relative "devdash/reprocessing/reprocessor"

# Loading the library defines classes and registries only.  Database
# connection, migrations, credentials, and source transports are deliberately
# owned by command execution (see Devdash::CLI and the command objects).
require_relative "devdash/models/pull_request"
require_relative "devdash/models/pull_request_event"
require_relative "devdash/models/pull_request_review"
require_relative "devdash/models/pull_request_file"
require_relative "devdash/models/commit"
require_relative "devdash/models/commit_file"
require_relative "devdash/models/linear_issue"
require_relative "devdash/models/linear_issue_event"
require_relative "devdash/models/issue_repository_link"
require_relative "devdash/models/metric_definition"
require_relative "devdash/models/metric_framework_mapping"
require_relative "devdash/models/report_snapshot"
require_relative "devdash/metrics/definition"
require_relative "devdash/metrics/window"
require_relative "devdash/metrics/weekday_normalizer"
require_relative "devdash/metrics/statistics"
require_relative "devdash/metrics/result"
require_relative "devdash/metrics/comparison"
require_relative "devdash/metrics/coverage"
require_relative "devdash/metrics/registry"
require_relative "devdash/metrics/report_cache"
require_relative "devdash/identity/manual_configuration"
require_relative "devdash/identity/person_merger"
require_relative "devdash/identity/resolver"
require_relative "devdash/identity/role_normalizer"
require_relative "devdash/identity/cohort_resolver"
require_relative "devdash/identity/issue_repository_resolver"
require_relative "devdash/sources/github/normalizer"
require_relative "devdash/sources/github/client"
require_relative "devdash/sources/github/collector"
require_relative "devdash/sources/linear/normalizer"
require_relative "devdash/sources/linear/client"
require_relative "devdash/sources/linear/collector"
require_relative "devdash/sources/slack/user_normalizer"
require_relative "devdash/sources/slack/client"
require_relative "devdash/sources/slack/collector"
require_relative "devdash/metrics/github/register"
require_relative "devdash/metrics/linear/register"
require_relative "devdash/reporting/report"
require_relative "devdash/reporting/framework_coverage"
require_relative "devdash/reporting/report_builder"
require_relative "devdash/reporting/terminal_renderer"
require_relative "devdash/commands/base"
require_relative "devdash/commands/sync"
require_relative "devdash/commands/backfill"
require_relative "devdash/commands/report"
require_relative "devdash/commands/reprocess"
require_relative "devdash/commands/rebuild_derived"
require_relative "devdash/cli"

module Devdash
  class << self
    # The only place where the application's metric registry is assembled.
    # `persist: false` is safe before a database exists; persistence is opt-in
    # after a command has connected and migrated SQLite.
    def build_metric_registry(persist: false)
      registry = Metrics::Registry.new
      Metrics::Github::Register.call(registry)
      Metrics::Linear::Register.call(registry)
      registry.persist! if persist
      registry
    end

    alias metric_registry build_metric_registry

    def register_source_normalizers!
      Sources::Github.register_normalizer!
      Sources::Linear.register_normalizer!
      Sources::Slack.register_normalizer!
    end
  end
end
