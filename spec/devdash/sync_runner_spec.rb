# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/devdash/sync_runner"

RSpec.describe Devdash::SyncRunner do
  let(:configuration) do
    Devdash::Configuration.new(raw: {
      "database_path" => ":memory:",
      "github" => { "repositories" => [
        { "name" => "acme/crm-web", "alias" => "crm-web", "default" => true, "enabled" => true },
        { "name" => "acme/other", "alias" => "other", "enabled" => true }
      ] }
    }, config_path: "config/devdash.yml")
  end
  let(:now) { Time.utc(2026, 9, 3, 12) }

  class RecordingCollector
    attr_reader :calls

    def initialize(failure: nil)
      @failure = failure
      @calls = []
    end

    def call(**options)
      @calls << options
      raise @failure if @failure

      :collected
    end
  end

  it "runs each selected repository and each global source independently" do
    github = RecordingCollector.new
    linear = RecordingCollector.new
    slack = RecordingCollector.new

    summary = described_class.new(configuration:, github_collector: github, linear_collector: linear,
      slack_collector: slack, clock: -> { now }).call(source: "all", repository_selector: "all")

    expect(summary.exit_status).to eq(0)
    expect(summary.succeeded.map(&:scope_key)).to eq(["acme/crm-web", "acme/other", "global", "workspace"])
    expect(github.calls.map { |call| call[:repository_scope].repository_names })
      .to eq([["acme/crm-web"], ["acme/other"]])
    expect(github.calls.map { |call| call[:since] }).to all(eq(now - ((360 + 7) * 86_400)))
    expect(linear.calls).to eq([{ since: now - ((360 + 7) * 86_400) }])
    expect(slack.calls).to eq([{}])
  end

  it "reports progress before and after each connector scope" do
    progress = []
    github = RecordingCollector.new
    linear = RecordingCollector.new
    slack = RecordingCollector.new

    summary = described_class.new(configuration:, github_collector: github, linear_collector: linear,
      slack_collector: slack, clock: -> { now }, progress: ->(message) { progress << message })
      .call(source: "all", repository_selector: "crm-web")

    expect(summary.exit_status).to eq(0)
    expect(progress).to include(
      "github/acme/crm-web: starting",
      "github/acme/crm-web: finished",
      "linear/global: starting",
      "linear/global: finished",
      "slack/workspace: starting",
      "slack/workspace: finished"
    )
    expect(progress.index("github/acme/crm-web: starting")).to be < progress.index("github/acme/crm-web: finished")
    expect(progress.index("linear/global: starting")).to be < progress.index("linear/global: finished")
  end

  it "attempts remaining units after a repository failure and returns a failed summary" do
    github = RecordingCollector.new(failure: RuntimeError.new("repo unavailable"))
    linear = RecordingCollector.new
    slack = RecordingCollector.new

    summary = described_class.new(configuration:, github_collector: github, linear_collector: linear,
      slack_collector: slack, clock: -> { now }).call(source: "all", repository_selector: "all")

    expect(summary.exit_status).to eq(1)
    expect(summary.failed.map(&:scope_key)).to eq(["acme/crm-web", "acme/other"])
    expect(summary.succeeded.map(&:scope_key)).to eq(["global", "workspace"])
    expect(linear.calls).not_to be_empty
    expect(slack.calls).not_to be_empty
    expect(summary.failed.first.error_message).to eq("github/acme/crm-web: repo unavailable")
  end

  it "qualifies repository selector errors with the connector" do
    expect do
      described_class.new(configuration:).call(source: "all", repository_selector: "missing")
    end.to raise_error(Devdash::ConfigurationError, /github: .*missing/)
  end

  it "uses the configured overlap after an existing source cursor" do
    connect_test_database!
    Devdash::Models::SyncCursor.create!(source: "github", scope_key: "acme/crm-web", cursor_type: "updated_at",
      cursor_value: (now - 3_600).iso8601, last_succeeded_at: now - 3_600)
    Devdash::Models::SyncCursor.create!(source: "linear", scope_key: "global", cursor_type: "updated_at",
      cursor_value: (now - 3_600).iso8601, last_succeeded_at: now - 3_600)

    github = RecordingCollector.new
    linear = RecordingCollector.new
    described_class.new(configuration:, github_collector: github, linear_collector: linear,
      slack_collector: RecordingCollector.new, clock: -> { now }, overlap_seconds: 86_400)
      .call(source: "all", repository_selector: "crm-web")

    expect(github.calls.fetch(0).fetch(:since)).to eq(now - 3_600 - 86_400)
    expect(linear.calls.fetch(0).fetch(:since)).to eq(now - 3_600 - 86_400)
  end

  it "rejects repository selectors for global-only source runs" do
    expect do
      described_class.new(configuration:).call(source: "linear", repository_selector: "crm-web")
    end.to raise_error(Devdash::Commands::UsageError, /only valid for GitHub or all/)
  end
end
