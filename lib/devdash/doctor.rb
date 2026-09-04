# frozen_string_literal: true

require "json"
require "pathname"
require "rbconfig"
require "sqlite3"
require "time"

module Devdash
  # Read-only local and credential diagnostics.  A doctor result intentionally
  # contains only check metadata; it never carries API responses or credential
  # values so it is safe to print and attach to a local bug report.
  class Doctor
    Check = Data.define(:key, :status, :severity, :message, :remediation) do
      def ok?
        severity != "error"
      end

      def to_h
        { key:, status:, severity:, message:, remediation: }
      end
    end

    Result = Data.define(:checks, :checked_at) do
      def errors
        checks.select { |check| check.severity == "error" }
      end

      def warnings
        checks.select { |check| check.severity == "warning" }
      end

      def healthy?
        errors.empty?
      end

      def exit_status
        healthy? ? 0 : 1
      end

      def to_h
        { checked_at: checked_at.utc.iso8601, checks: checks.map(&:to_h), exit_status: exit_status }
      end
    end

    REQUIRED_TOOLS = %w[gh jq rg ast-grep].freeze
    MAINTAINER_TOOLS = %w[jq rg ast-grep].freeze
    REQUIRED_REPORT_WINDOWS = %w[7d 30d 180d].freeze
    DEFAULT_FRESHNESS_SECONDS = 2 * 86_400

    def initialize(configuration: nil, database_path: nil, offline: false, clock: -> { Time.now.utc },
                   executable_lookup: nil, github_probe: nil, linear_probe: nil,
                   slack_probe: nil, github_client: nil, linear_client: nil, slack_client: nil, http: nil,
                   linear_token: ENV["LINEAR_API_KEY"], slack_token: ENV["SLACK_TOKEN"] || ENV["SLACK_API_TOKEN"],
                   registry: nil, freshness_seconds: nil)
      @configuration = configuration
      @database_path = database_path
      @offline = offline
      @clock = clock
      @executable_lookup = executable_lookup || ->(name) { self.class.send(:executable_path, name) }
      @github_probe = github_probe
      @linear_probe = linear_probe
      @slack_probe = slack_probe
      @github_client = github_client
      @linear_client = linear_client
      @slack_client = slack_client
      @http = http
      @linear_token = linear_token
      @slack_token = slack_token
      @registry = registry
      @freshness_seconds = freshness_seconds || configuration_value(:freshness_seconds, DEFAULT_FRESHNESS_SECONDS)
    end

    def call
      checks = []
      configuration = load_configuration(checks)
      checks << configuration_check(configuration)
      checks.concat(tool_checks)
      checks << database_check(configuration)
      checks.concat(access_checks(configuration))
      checks.concat(data_checks(configuration))
      checks << report_availability_check
      Result.new(checks: checks.compact.freeze, checked_at: now)
    end

    class << self
      private

      def executable_path(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
          candidate = File.join(directory, name)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end
    end

    private

    def load_configuration(checks)
      return @configuration if @configuration
      path = ENV.fetch("DEVDASH_CONFIG", Devdash.root.join("config/devdash.yml"))
      @configuration = Configuration.load(path:)
    rescue Devdash::Error => error
      checks << error_check("configuration", "configuration is invalid", error.message,
        "Copy config/devdash.example.yml to config/devdash.yml and correct the reported fields.")
      nil
    end

    def configuration_check(configuration)
      return error_check("configuration", "configuration could not be loaded", "configuration is unavailable",
        "Create a valid local configuration.") unless configuration

      default_count = configuration.repositories.count(&:default)
      enabled_count = configuration.repositories.count { |repository| repository.default && repository.enabled }
      if default_count == 1 && enabled_count == 1
        check("configuration", "ok", "configuration is valid with one enabled default repository",
          "No action required.")
      else
        error_check("configuration", "repository defaults are invalid",
          "expected exactly one configured and enabled default repository",
          "Set default: true on exactly one enabled GitHub repository.")
      end
    rescue StandardError => error
      error_check("configuration", "configuration is invalid", safe_message(error),
        "Correct config/devdash.yml and rerun doctor.")
    end

    def tool_checks
      missing = REQUIRED_TOOLS.reject { |name| @executable_lookup.call(name) }
      required_missing = missing & ["gh"]
      maintainer_missing = missing & MAINTAINER_TOOLS
      if required_missing.any?
        message = "missing gh#{maintainer_missing.any? ? "; also missing #{maintainer_missing.join(", ")}" : ""}"
        [error_check("tools", "missing tools", message, "Install GitHub CLI and rerun gh auth status.")]
      elsif maintainer_missing.any?
        [warning_check("tools", "missing maintainer tools", "missing #{maintainer_missing.join(", ")}",
          "Install the missing developer tools for source inspection; dashboard collection can continue.")]
      else
        [check("tools", "ok", "gh, jq, rg, and ast-grep are available", "No action required.")]
      end
    rescue StandardError => error
      [error_check("tools", "tool check failed", safe_message(error), "Check the local executable PATH.")]
    end

    def database_check(configuration)
      path = Pathname(@database_path || configuration&.database_path || Devdash.root.join("data/devdash.sqlite3"))
      unless path.to_s == ":memory:"
        unless path.file?
          return warning_check("database", "missing", "database file is not present", "Run mise exec -- bin/setup.")
        end
        unless File.readable?(path) && File.writable?(path)
          return error_check("database", "permissions", "database file is not readable and writable", "Fix local database permissions.")
        end
      end

      version = schema_versions(path)
      expected = Dir[Devdash.root.join("db/migrate/*.rb").to_s].map { |file| File.basename(file).split("_", 2).first }.sort
      if (expected - version).empty?
        check("database", "ok", "database is readable and schema is current", "No action required.")
      else
        error_check("database", "schema is behind", "database schema is missing #{(expected - version).join(", ")} migration(s)",
          "Run mise exec -- bin/setup to migrate the local database.")
      end
    rescue SQLite3::Exception => error
      error_check("database", "unreadable", safe_message(error), "Run setup or repair the local SQLite file.")
    rescue StandardError => error
      warning_check("database", "unavailable", safe_message(error), "Run setup and rerun doctor.")
    end

    def access_checks(configuration)
      return [] unless configuration
      repositories = configuration.repositories.select(&:enabled)
      checks = []
      if @offline
        checks << skipped_check("github_access", "offline mode skipped GitHub access probes")
        checks << if @linear_token.to_s.empty?
          error_check("linear_access", "missing credential", "Linear credential is not configured",
            "Set LINEAR_API_KEY before running an online doctor probe.")
        else
          skipped_check("linear_access", "offline mode skipped Linear access probe")
        end
        checks << if @slack_token.to_s.empty?
          error_check("slack_access", "missing credential", "Slack credential is not configured",
            "Set SLACK_TOKEN before running an online doctor probe.")
        else
          skipped_check("slack_access", "offline mode skipped Slack access probe")
        end
        return checks
      end

      github_errors = repositories.filter_map do |repository|
        begin
          github_probe.call(repository.name)
          nil
        rescue StandardError => error
          "#{repository.alias_name}: #{safe_message(error)}"
        end
      end
      checks << if github_errors.empty?
        check("github_access", "ok", "GitHub access succeeded for all configured repositories", "No action required.")
      else
        error_check("github_access", "access failed", github_errors.join("; "), "Run gh auth status and verify repository read access.")
      end

      checks << credential_probe("linear_access", @linear_token, "Linear", linear_probe,
        "Set LINEAR_API_KEY and verify read access to the configured workspace.")
      checks << credential_probe("slack_access", @slack_token, "Slack", slack_probe,
        "Set SLACK_TOKEN (or SLACK_API_TOKEN) and verify users.list access.")
      checks
    end

    def credential_probe(key, token, name, probe, remediation)
      return error_check(key, "missing credential", "#{name} credential is not configured", remediation) if token.to_s.empty?

      begin
        probe.call
        check(key, "ok", "#{name} access probe succeeded", "No action required.")
      rescue StandardError => error
        error_check(key, "access failed", safe_message(error), remediation)
      end
    end

    def github_probe
      @github_probe ||= begin
        client = @github_client || Sources::Github::Client.new
        ->(repository) { client.repository(repository) }
      end
    end

    def linear_probe
      @linear_probe ||= begin
        if @linear_client
          -> { @linear_client.each_issue(updated_since: now - 60).first }
        else
          transport = @http || Transports::HttpJson.new(base_uri: "https://api.linear.app")
          -> {
            transport.post(path: "/graphql", headers: { "Authorization" => @linear_token, "Content-Type" => "application/json" },
              body: { "query" => "query Doctor { viewer { id } }", "variables" => {} })
          }
        end
      end
    end

    def slack_probe
      @slack_probe ||= begin
        transport = Transports::HttpJson.new(base_uri: "https://slack.com")
        client = @slack_client || Sources::Slack::Client.new(transport:, token: @slack_token)
        -> { client.each_user.first }
      end
    end

    def data_checks(configuration)
      return [skipped_check("identity", "database state checks skipped because database is unavailable")] unless active_record_ready?

      checks = []
      checks << identity_check
      checks << links_check
      checks << coverage_check
      checks
    rescue StandardError => error
      [warning_check("data", "inspection unavailable", safe_message(error), "Run a successful sync and rerun doctor.")]
    end

    def identity_check
      owner = Models::Person.find_by(owner: true)
      return error_check("identity", "owner unresolved", "no resolved owner is present", "Run sync with config/people.yml configured.") unless owner

      unresolved = Models::SourceIdentity.where(resolution_method: %w[unresolved provisional]).count
      ambiguous = Models::SourceIdentity.where(resolution_method: "ambiguous").count
      unknown_roles = Models::RoleAssignment.where(normalized_role: [nil, "", "unknown"])
        .or(Models::RoleAssignment.where(normalized_level: [nil, "", "unknown"])).count
      cohort_size = begin
        configuration = @configuration || Configuration.load(path: ENV.fetch("DEVDASH_CONFIG", Devdash.root.join("config/devdash.yml")))
        Identity::CohortResolver.new(configuration: Identity::ManualConfiguration.load(
          path: ENV.fetch("DEVDASH_PEOPLE_CONFIG", Devdash.root.join("config/people.yml")),
          repository_aliases: configuration.repositories.map(&:alias_name), repository_names: configuration.repositories.map(&:name)
        )).call(owner:, at: now, repository_scope: configuration.resolve_repository_scope("all")).included_ids.length
      rescue StandardError
        nil
      end
      if unresolved.positive? || ambiguous.positive? || unknown_roles.positive?
        warning_check("identity", "needs attention", "owner resolved; unresolved=#{unresolved}, ambiguous=#{ambiguous}, unnormalized_roles=#{unknown_roles}, cohort_n=#{cohort_size || "unavailable"}",
          "Resolve identities and normalize titles before interpreting peer comparisons.")
      else
        check("identity", "ok", "owner, identities, roles, and cohort are resolved (cohort_n=#{cohort_size || "unavailable"})", "No action required.")
      end
    end

    def links_check
      unresolved = Models::IssueRepositoryLink.where.not(resolution_status: "resolved").count
      multi_repo = Models::IssueRepositoryLink.where(resolution_status: "resolved").group(:linear_issue_id).having("COUNT(repository_id) > 1").count.length
      return warning_check("linear_links", "needs attention", "unresolved=#{unresolved}, multi_repo=#{multi_repo}",
        "Review Linear repository evidence; ambiguous links remain visible and are excluded from single-repository attribution.") if unresolved.positive? || multi_repo.positive?

      check("linear_links", "ok", "Linear repository links are resolved without multi-repository ambiguity", "No action required.")
    end

    def coverage_check
      rows = Models::CollectorRunCoverage.joins(:collector_run).where(status: "complete").to_a
      return warning_check("coverage", "unavailable", "no successful source coverage is recorded", "Run sync or backfill.") if rows.empty?

      stale = rows.select do |row|
        finished = row.collector_run.finished_at || row.achieved_end_at
        finished && (now - finished) > @freshness_seconds
      end
      if stale.empty?
        check("coverage", "ok", "source coverage is present and fresh", "No action required.")
      else
        warning_check("coverage", "stale", "#{stale.length} coverage interval(s) are older than the freshness setting", "Run sync for the affected source or repository.")
      end
    end

    def report_availability_check
      return skipped_check("reports", "report availability requires a migrated database") unless active_record_ready?

      present = Models::ReportSnapshot.all.to_a
        .filter_map { |snapshot| report_window(snapshot.window_start_at, snapshot.window_end_at) }.uniq
      missing = REQUIRED_REPORT_WINDOWS - present
      if missing.empty?
        check("reports", "ok", "7d, 30d, and 180d report snapshots are available", "No action required.")
      else
        warning_check("reports", "not yet cached", "missing #{missing.join(", ")} report snapshot(s)", "Run devdash report --window WINDOW for each missing window.")
      end
    rescue StandardError => error
      warning_check("reports", "unavailable", safe_message(error), "Run a report after setup.")
    end

    def report_window(start_at, end_at)
      seconds = end_at.to_f - start_at.to_f
      return "7d" if (seconds - 7 * 86_400).abs < 1
      return "30d" if (seconds - 30 * 86_400).abs < 1
      return "180d" if (seconds - 180 * 86_400).abs < 1
    end

    def active_record_ready?
      defined?(ActiveRecord::Base) && ActiveRecord::Base.connected? &&
        ActiveRecord::Base.connection.table_exists?("people")
    end

    def with_readonly_db(path)
      return yield(SQLite3::Database.new(":memory:")) if path.to_s == ":memory:"

      db = SQLite3::Database.new(path.to_s, readonly: true)
      db.results_as_hash = false
      yield(db)
    ensure
      db&.close
    end

    def schema_versions(path)
      if path.to_s == ":memory:" && defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
        return ActiveRecord::Base.connection.select_values("SELECT version FROM schema_migrations ORDER BY version").map(&:to_s)
      end

      with_readonly_db(path) { |db| db.execute("SELECT version FROM schema_migrations ORDER BY version").flatten.map(&:to_s) }
    end

    def configuration_value(name, fallback)
      @configuration.respond_to?(name) ? @configuration.public_send(name) : fallback
    end

    def check(key, status, message, remediation)
      Check.new(key:, status:, severity: "info", message: safe_text(message), remediation: safe_text(remediation))
    end

    def warning_check(key, status, message, remediation)
      Check.new(key:, status:, severity: "warning", message: safe_text(message), remediation: safe_text(remediation))
    end

    def error_check(key, status, message, remediation)
      Check.new(key:, status:, severity: "error", message: safe_text(message), remediation: safe_text(remediation))
    end

    def skipped_check(key, message)
      Check.new(key:, status: "skipped", severity: "info", message: safe_text(message), remediation: "Run without --offline to perform access probes.")
    end

    def safe_message(error)
      Transports::Sanitizer.sanitize(error.message.to_s).slice(0, 500)
    rescue StandardError
      "#{error.class.name}"
    end

    def safe_text(value)
      value.to_s.gsub(/(?:Bearer\s+|token\s*[:=]\s*|api[_-]?key\s*[:=]\s*)\S+/i, "[redacted]")
        .gsub(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, "[redacted-email]").slice(0, 500)
    end

    def now
      value = @clock.call
      value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
    end
  end
end
