# frozen_string_literal: true

module Devdash
  module Commands
    class Sync < Base
      SOURCES = %w[github linear slack all].freeze

      def initialize(configuration: nil, out: $stdout, err: $stderr, database: Devdash::Database,
                     clock: -> { Time.now.utc }, github_collector: nil, linear_collector: nil,
                     slack_collector: nil, github_client: nil, linear_client: nil, slack_client: nil, http: nil,
                     cache: nil)
        super(configuration:, out:, err:, database:, clock:)
        @github_collector = github_collector
        @linear_collector = linear_collector
        @slack_collector = slack_collector
        @github_client = github_client
        @linear_client = linear_client
        @slack_client = slack_client
        @http = http
        @cache = cache
      end

      def call(source: "all", repository_selector: nil, repo: nil)
        source = source.to_s
        repository_selector ||= repo
        raise UsageError, "unknown source #{source.inspect}; expected github, linear, slack, or all" unless SOURCES.include?(source)
        if repository_selector && %w[linear slack].include?(source)
          raise UsageError, "--repo is only valid for GitHub or all-source sync"
        end

        prepare_database!
        Devdash.register_source_normalizers!
        scope = repository_scope(repository_selector)
        selected = source == "all" ? SOURCES - ["all"] : [source]
        selected.each do |item|
          case item
          when "github" then github_collector.call(repository_scope: scope)
          when "linear" then linear_collector.call(since: clock.call.utc - (7 * 86_400))
          when "slack" then slack_collector.call
          end
        end
        Reprocessing::Reprocessor.new(registry: Normalizers::Registry, derived_rebuilder: nil).call
        resolve_identity_and_links
        clear_report_cache!
        0
      end

      private

      attr_reader :github_collector, :linear_collector, :slack_collector

      def github_collector
        @github_collector ||= Sources::Github::Collector.new(client: @github_client || Sources::Github::Client.new)
      end

      def linear_collector
        @linear_collector ||= Sources::Linear::Collector.new(client: @linear_client || default_linear_client)
      end

      def slack_collector
        @slack_collector ||= Sources::Slack::Collector.new(client: @slack_client || default_slack_client)
      end

      def default_linear_client
        Sources::Linear::Client.new(http: @http || Transports::HttpJson.new(base_uri: "https://api.linear.app"))
      end

      def default_slack_client
        token = ENV.fetch("SLACK_TOKEN") { ENV.fetch("SLACK_API_TOKEN") { raise ConfigurationError, "SLACK_TOKEN is required" } }
        Sources::Slack::Client.new(transport: @http || Transports::HttpJson.new(base_uri: "https://slack.com"), token:)
      end

      def resolve_identity_and_links
        config = identity_configuration
        return unless config

        Identity::Resolver.new(configuration: config, clock:).call
        Identity::RoleNormalizer.new(configuration: config, clock:).tap do |normalizer|
          Models::Person.find_each do |person|
            assignment = person.role_assignments.where(source: "slack").order(effective_from: :desc).first
            normalizer.call(role_assignment: assignment) if assignment
          end
        end
        Identity::IssueRepositoryResolver.new(configuration: config).call
      end

      def clear_report_cache!
        return @cache.clear! if @cache
        return unless ActiveRecord::Base.connected?

        Metrics::ReportCache.new.clear!
      end
    end
  end
end
