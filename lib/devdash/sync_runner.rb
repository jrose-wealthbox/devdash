# frozen_string_literal: true

require "time"

module Devdash
  # Coordinates independent source scopes for the once-daily sync.  A scope is
  # deliberately the unit of failure: a broken repository does not prevent
  # another repository, Linear, or Slack from being attempted.
  class SyncRunner
    Unit = Data.define(:source, :scope_key, :repository_names, :status, :started_at, :finished_at,
      :value, :error_class, :error_message) do
      def succeeded?
        status == "succeeded"
      end

      def failed?
        status == "failed"
      end
    end

    Summary = Data.define(:results, :started_at, :finished_at) do
      def succeeded
        results.select(&:succeeded?)
      end

      def failed
        results.select(&:failed?)
      end

      def exit_status
        failed.empty? ? 0 : 1
      end

      def success?
        failed.empty?
      end

      def to_h
        {
          results: results.map(&:to_h),
          succeeded: succeeded.map(&:scope_key),
          failed: failed.map(&:scope_key),
          exit_status: exit_status
        }
      end
    end

    SOURCES = %w[github linear slack all].freeze
    GLOBAL_SCOPES = { "linear" => "global", "slack" => "workspace" }.freeze
    DEFAULT_OVERLAP_SECONDS = 48 * 3600
    DEFAULT_INITIAL_BACKFILL_DAYS = 360
    DEFAULT_SAFETY_MARGIN_DAYS = 7

    attr_reader :configuration

    def initialize(configuration:, github_collector: nil, linear_collector: nil, slack_collector: nil,
                   github_client: nil, linear_client: nil, slack_client: nil, http: nil,
                   clock: -> { Time.now.utc }, overlap_seconds: nil, initial_backfill_days: nil,
                   safety_margin_days: nil, cursor_store: nil, progress: nil)
      @configuration = configuration
      @github_collector = github_collector
      @linear_collector = linear_collector
      @slack_collector = slack_collector
      @github_client = github_client
      @linear_client = linear_client
      @slack_client = slack_client
      @http = http
      @clock = clock
      @overlap_seconds = integer_setting(overlap_seconds, :overlap_seconds, DEFAULT_OVERLAP_SECONDS)
      @initial_backfill_days = [integer_setting(initial_backfill_days, :initial_backfill_days, DEFAULT_INITIAL_BACKFILL_DAYS),
        DEFAULT_INITIAL_BACKFILL_DAYS].max
      @safety_margin_days = integer_setting(safety_margin_days, :safety_margin_days, DEFAULT_SAFETY_MARGIN_DAYS)
      @cursor_store = cursor_store
      @progress = progress
      validate_settings!
    end

    def call(source: "all", repository_selector: nil, repo: nil, scope: nil, since: nil)
      source = source.to_s
      selector = repository_selector || repo || scope
      validate_source!(source)
      if selector && %w[linear slack].include?(source)
        raise Commands::UsageError, "#{source}: --repo is only valid for GitHub or all-source sync"
      end

      started_at = now
      units = planned_units_with_context(source:, selector:)
      results = units.map { |unit| run_unit(unit, requested_since: since, started_at:) }
      Summary.new(results:, started_at:, finished_at: now)
    end

    private

    def planned_units(source:, selector:)
      selected = source == "all" ? %w[github linear slack] : [source]
      repository_scope = if selected.include?("github")
        configuration.resolve_repository_scope(selector || default_selector_for(source))
      end

      selected.flat_map do |item|
        if item == "github"
          repository_scope.repository_names.sort.map do |name|
            Unit.new(source: "github", scope_key: name, repository_names: [name], status: nil,
              started_at: nil, finished_at: nil, value: nil, error_class: nil, error_message: nil)
          end
        else
          Unit.new(source: item, scope_key: GLOBAL_SCOPES.fetch(item), repository_names: [], status: nil,
            started_at: nil, finished_at: nil, value: nil, error_class: nil, error_message: nil)
        end
      end
    end

    def default_selector_for(source)
      # `sync all` historically means the default repository.  Explicit
      # `--repo all` opts into the independent all-repository fan-out.
      source == "github" ? nil : nil
    end

    def run_unit(unit, requested_since:, started_at:)
      unit_started_at = now
      report("#{unit.source}/#{unit.scope_key}: starting")
      value = collect(unit, requested_since: requested_since)
      report("#{unit.source}/#{unit.scope_key}: finished")
      Unit.new(source: unit.source, scope_key: unit.scope_key, repository_names: unit.repository_names,
        status: "succeeded", started_at: unit_started_at, finished_at: now, value:, error_class: nil, error_message: nil)
    rescue StandardError => error
      error_message = qualified_error_message(unit, error)
      report("#{unit.source}/#{unit.scope_key}: failed: #{sanitized_message(error)}")
      Unit.new(source: unit.source, scope_key: unit.scope_key, repository_names: unit.repository_names,
        status: "failed", started_at: unit_started_at || started_at, finished_at: now, value: nil,
        error_class: error.class.name, error_message: error_message)
    end

    def planned_units_with_context(source:, selector:)
      planned_units(source:, selector:)
    rescue StandardError => error
      connector = source == "all" ? "github" : source
      raise error.class, "#{connector}: #{sanitized_message(error)}", error.backtrace
    end

    def collect(unit, requested_since:)
      case unit.source
      when "github"
        collector(:github).call(repository_scope: single_scope(unit.scope_key), since: since_for("github", unit.scope_key, requested_since))
      when "linear"
        collector(:linear).call(since: since_for("linear", "global", requested_since))
      when "slack"
        collector(:slack).call
      end
    end

    def single_scope(name)
      configuration.resolve_repository_scope(name)
    end

    def since_for(source, scope_key, requested_since)
      explicit = parse_time(requested_since)
      return explicit if explicit

      cursor = cursor_value(source, scope_key)
      if cursor
        cursor - @overlap_seconds
      else
        now - ((@initial_backfill_days + @safety_margin_days) * 86_400)
      end
    end

    def cursor_value(source, scope_key)
      if @cursor_store
        value = if @cursor_store.respond_to?(:call)
          @cursor_store.call(source:, scope_key:)
        elsif @cursor_store.respond_to?(:fetch)
          @cursor_store.fetch([source, scope_key], nil)
        end
        return parse_time(value)
      end
      return unless defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
      return unless defined?(Models::SyncCursor)

      parse_time(Models::SyncCursor.find_by(source:, scope_key:, cursor_type: "updated_at")&.cursor_value)
    end

    def collector(name)
      ivar = "@#{name}_collector"
      value = instance_variable_get(ivar)
      return value if value

      value = case name
      when :github
        Sources::Github::Collector.new(client: @github_client || Sources::Github::Client.new, progress: method(:report))
      when :linear
        Sources::Linear::Collector.new(client: @linear_client || Sources::Linear::Client.new(
          http: @http || Transports::HttpJson.new(base_uri: "https://api.linear.app")
        ), progress: method(:report))
      when :slack
        token = ENV.fetch("SLACK_TOKEN") { ENV.fetch("SLACK_API_TOKEN") { raise ConfigurationError, "SLACK_TOKEN is required" } }
        Sources::Slack::Collector.new(client: @slack_client || Sources::Slack::Client.new(
          transport: @http || Transports::HttpJson.new(base_uri: "https://slack.com"), token:))
      end
      instance_variable_set(ivar, value)
    end

    def validate_source!(source)
      return if SOURCES.include?(source)

      raise Commands::UsageError, "unknown source #{source.inspect}; expected github, linear, slack, or all"
    end

    def integer_setting(value, method, default)
      value = configuration.public_send(method) if value.nil? && configuration.respond_to?(method)
      value = default if value.nil?
      Integer(value)
    rescue ArgumentError, TypeError
      raise ConfigurationError, "#{method} must be an integer"
    end

    def validate_settings!
      raise ConfigurationError, "overlap_seconds must be non-negative" if @overlap_seconds.negative?
      raise ConfigurationError, "initial_backfill_days must be positive" unless @initial_backfill_days.positive?
      raise ConfigurationError, "safety_margin_days must be non-negative" if @safety_margin_days.negative?
    end

    def parse_time(value)
      return value.utc if value.respond_to?(:utc)
      return if value.to_s.strip.empty?

      Time.iso8601(value.to_s).utc
    rescue ArgumentError, TypeError
      nil
    end

    def now
      value = @clock.call
      value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
    end

    def sanitized_message(error)
      Transports::Sanitizer.sanitize(error.message.to_s).slice(0, 500)
    rescue NameError
      error.message.to_s.gsub(/(token|authorization|api[_-]?key)\s*[:=]\s*\S+/i, '\\1=[redacted]').slice(0, 500)
    end

    def qualified_error_message(unit, error)
      "#{unit.source}/#{unit.scope_key}: #{sanitized_message(error)}"
    end

    def report(message)
      @progress&.call(message)
    end
  end
end
