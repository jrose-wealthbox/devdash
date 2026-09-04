# frozen_string_literal: true

require "json"
require "spec_helper"
require_relative "../../lib/devdash/sync_runner"

RSpec.describe "fixture-backed dashboard acceptance" do
  let(:now) { Time.utc(2026, 9, 3, 12) }
  let(:configuration) do
    Devdash::Configuration.new(raw: {
      "database_path" => ":memory:", "sync" => { "initial_backfill_days" => 360, "safety_margin_days" => 7 },
      "github" => { "repositories" => [
        { "name" => "acme/crm-web", "alias" => "crm-web", "default" => true, "enabled" => true },
        { "name" => "acme/other", "alias" => "other", "default" => false, "enabled" => true }
      ] }
    }, config_path: "config/devdash.yml")
  end

  class FixtureCollector
    attr_reader :calls

    def initialize(source:, writer:, fixtures:, fail_scope: nil)
      @source, @writer, @fixtures, @fail_scope = source, writer, fixtures, fail_scope
      @calls = []
    end

    def call(**options)
      scope_key = @source == "github" ? options.fetch(:repository_scope).repository_names.fetch(0) : @source == "linear" ? "global" : "workspace"
      @calls << options.merge(scope_key: scope_key)
      raise "fixture failure for #{scope_key}" if scope_key == @fail_scope

      observations = @fixtures.fetch(scope_key)
      @writer.call(Devdash::Ingestion::Batch.new(source: @source, scope_key:, cursor_type: "updated_at",
        cursor_before: nil, cursor_after: "2026-09-03T12:00:00Z", observations:, coverages: [], page_count: 1, retry_count: 0))
    end
  end

  before do
    connect_test_database!
    Devdash.register_source_normalizers!
  end

  def observation(source, entity_type, external_id, payload, scope_key:, updated_at: now)
    Devdash::Ingestion::SourceObservation.new(entity_type:, external_id:, source_updated_at: updated_at,
      observed_at: now, api_version: "fixture", query_fingerprint: "fixture:#{entity_type}", payload:)
  end

  def github_fixtures(name)
    pull = { "number" => 1, "node_id" => "PR_#{name}", "state" => "open", "draft" => false,
      "user" => { "login" => "jrose" }, "base" => { "ref" => "main" }, "head" => { "sha" => "head-#{name}" },
      "merge_commit_sha" => nil, "created_at" => "2026-09-01T00:00:00Z", "closed_at" => nil,
      "merged_at" => nil, "updated_at" => "2026-09-02T00:00:00Z", "additions" => 3, "deletions" => 1,
      "changed_files" => 1 }
    [observation("github", "repository", "github:#{name}:repository", { "full_name" => name, "node_id" => "repo-#{name}", "default_branch" => "main" }, scope_key: name),
      observation("github", "pull_request", "github:#{name}:pull:1", pull, scope_key: name),
      observation("github", "pull_request_reviews", "github:#{name}:pull_reviews:1", [], scope_key: name),
      observation("github", "pull_request_timeline", "github:#{name}:pull_event:1", [], scope_key: name),
      observation("github", "pull_request_files", "github:#{name}:pull_files:1", [{ "filename" => "app.rb", "status" => "modified", "additions" => 3, "deletions" => 1, "_pull_number" => 1 }], scope_key: name)]
  end

  def linear_fixtures
    payload = { "id" => "linear-1", "identifier" => "ENG-1", "title" => "Fixture issue", "url" => "https://linear.app/ENG-1",
      "updatedAt" => "2026-09-02T00:00:00Z", "createdAt" => "2026-09-01T00:00:00Z", "startedAt" => nil,
      "completedAt" => nil, "canceledAt" => nil, "archivedAt" => nil, "trashed" => false, "estimate" => 2,
      "team" => { "id" => "team-1", "name" => "Engineering" }, "project" => nil,
      "state" => { "id" => "state-1", "name" => "Todo", "type" => "backlog" }, "creator" => nil, "assignee" => nil,
      "labels" => { "nodes" => [] }, "attachments" => { "nodes" => [] } }
    [observation("linear", "linear_issue", "linear-1", payload, scope_key: "global"),
      observation("linear", "linear_issue_history", "linear-1:history", { "issue_id" => "linear-1", "history" => [] }, scope_key: "global")]
  end

  def slack_fixtures
    [observation("slack", "user", "U001", { "id" => "U001", "name" => "jrose", "real_name" => "John",
      "deleted" => false, "is_bot" => false, "is_restricted" => false, "is_ultra_restricted" => false,
      "profile" => { "display_name" => "John", "real_name" => "John", "title" => "Senior Software Engineer", "email" => "john@example.test" } }, scope_key: "workspace", updated_at: Time.at(now.to_i))]
  end

  it "is idempotent, renders every scope/window, and reprocesses after canonical deletion" do
    writer = Devdash::Ingestion::Writer.new
    github = FixtureCollector.new(source: "github", writer:, fixtures: {
      "acme/crm-web" => github_fixtures("acme/crm-web"), "acme/other" => github_fixtures("acme/other")
    })
    linear = FixtureCollector.new(source: "linear", writer:, fixtures: { "global" => linear_fixtures })
    slack = FixtureCollector.new(source: "slack", writer:, fixtures: { "workspace" => slack_fixtures })
    runner = Devdash::SyncRunner.new(configuration:, github_collector: github, linear_collector: linear, slack_collector: slack, clock: -> { now })

    expect(runner.call(source: "all", repository_selector: "all").exit_status).to eq(0)
    before_keys = Devdash::Models::SourceRecord.order(:id).pluck(:source, :scope_key, :entity_type, :external_id, :payload_hash)
    counts = [Devdash::Models::PullRequest.count, Devdash::Models::LinearIssue.count, Devdash::Models::Person.count]
    runner.call(source: "all", repository_selector: "all")
    expect(Devdash::Models::SourceRecord.order(:id).pluck(:source, :scope_key, :entity_type, :external_id, :payload_hash)).to eq(before_keys)
    expect([Devdash::Models::PullRequest.count, Devdash::Models::LinearIssue.count, Devdash::Models::Person.count]).to eq(counts)
    canonical_before = {
      pull_requests: Devdash::Models::PullRequest.joins(:repository).order("repositories.full_name", :number)
        .pluck("repositories.full_name", :number, :state),
      linear_issues: Devdash::Models::LinearIssue.order(:linear_id).pluck(:linear_id, :identifier, :state_name)
    }

    owner = Devdash::Models::Person.create!(display_name: "Owner", owner: true)
    cohort = instance_double("Cohort", included_ids: [], exclusions: {}, role: "unknown", level: "unknown")
    builder = Devdash::Reporting::ReportBuilder.new(registry: Devdash::Metrics::Registry.new,
      cohort_resolver: instance_double("CohortResolver", call: cohort), clock: -> { now })
    scope_build = ->(selector) { configuration.resolve_repository_scope(selector) }
    rendered = %w[7d 30d 180d].flat_map do |window|
      ["crm-web", "other", "all"].map do |selector|
        report = builder.call(owner:, window: Devdash::Metrics::Window.for(window, end_at: now), repository_scope: scope_build.call(selector))
        Devdash::Reporting::TerminalRenderer.new.render(report)
      end
    end
    expect(rendered.join).to include("7d", "30d", "180d", "crm-web", "other", "All configured repos")

    Devdash::Models::PullRequestFile.delete_all
    Devdash::Models::PullRequest.delete_all
    Devdash::Models::LinearIssueEvent.delete_all
    Devdash::Models::LinearIssue.delete_all
    calls_before_reprocess = [github.calls.length, linear.calls.length, slack.calls.length]
    expect { Devdash::Reprocessing::Reprocessor.new(registry: Devdash::Normalizers::Registry, derived_rebuilder: nil).call }.not_to raise_error
    expect(Devdash::Models::PullRequest.count).to eq(2)
    expect(Devdash::Models::LinearIssue.count).to eq(1)
    expect([github.calls.length, linear.calls.length, slack.calls.length]).to eq(calls_before_reprocess)
    expect({
      pull_requests: Devdash::Models::PullRequest.joins(:repository).order("repositories.full_name", :number)
        .pluck("repositories.full_name", :number, :state),
      linear_issues: Devdash::Models::LinearIssue.order(:linear_id).pluck(:linear_id, :identifier, :state_name)
    }).to eq(canonical_before)

    Devdash::Models::ReportSnapshot.delete_all
    database = instance_double("Database", connect!: nil, migrate!: nil)
    expect { Devdash::Commands::RebuildDerived.new(configuration:, database:, cache: Devdash::Metrics::ReportCache.new).call }.not_to raise_error
    expect(Devdash::Models::ReportSnapshot.count).to eq(0)
  end

  it "keeps successful repository facts when one all-scope repository fails" do
    writer = Devdash::Ingestion::Writer.new
    github = FixtureCollector.new(source: "github", writer:, fixtures: {
      "acme/crm-web" => github_fixtures("acme/crm-web"), "acme/other" => github_fixtures("acme/other")
    }, fail_scope: "acme/other")
    summary = Devdash::SyncRunner.new(configuration:, github_collector: github,
      linear_collector: FixtureCollector.new(source: "linear", writer:, fixtures: { "global" => linear_fixtures }),
      slack_collector: FixtureCollector.new(source: "slack", writer:, fixtures: { "workspace" => slack_fixtures }), clock: -> { now })
      .call(source: "all", repository_selector: "all")

    expect(summary.failed.map(&:scope_key)).to eq(["acme/other"])
    expect(Devdash::Models::SourceRecord.where(scope_key: "acme/crm-web")).to exist
    expect(Devdash::Models::SourceRecord.where(scope_key: "acme/other")).to be_empty
  end
end
