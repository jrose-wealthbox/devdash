# frozen_string_literal: true
require "devdash/sources/github/collector"

RSpec.describe Devdash::Sources::Github::Collector do
  before { connect_test_database! }

  it "expands every configured repository independently" do
    client = instance_double(Devdash::Sources::Github::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    allow(client).to receive(:repository).and_return({ "default_branch" => "main" })
    allow(client).to receive(:updated_pull_numbers).and_return([])
    allow(client).to receive(:open_pull_numbers).and_return([])
    allow(client).to receive(:default_branch_commits).and_return([])
    allow(client).to receive(:page_count).and_return(0)
    expect(writer).to receive(:call).twice
    scope = Devdash::RepositoryScope.new(key: "all", repository_names: ["o/a", "o/b"], label: "all", configuration_hash: "x")
    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 2) }).call(repository_scope: scope, since: Time.utc(2026, 1, 1))
  end

  it "uses each repository cursor with overlap and passes immutable scoped coverage" do
    client = instance_double(Devdash::Sources::Github::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    repository = { "default_branch" => "main", "updated_at" => "2026-01-04T00:00:00Z" }
    allow(client).to receive(:repository).with("o/r").and_return(repository)
    expect(client).to receive(:updated_pull_numbers).with("o/r", from: Time.utc(2026, 1, 1), to: Time.utc(2026, 1, 4)).and_return([])
    allow(client).to receive(:open_pull_numbers).with("o/r").and_return([])
    allow(client).to receive(:default_branch_commits).with("o/r", branch: "main", since: Time.utc(2026, 1, 1)).and_return([])
    allow(client).to receive(:page_count).and_return(4)
    expect(writer).to receive(:call) do |batch|
      expect(batch.cursor_before).to eq("2026-01-03T00:00:00Z")
      expect(batch.cursor_after).to eq("2026-01-04T00:00:00Z")
      expect(batch.page_count).to eq(4)
      expect(batch.coverages).to all(include(scope_type: "repository", scope_key: "o/r"))
      expect(batch.coverages).to all(be_frozen)
    end

    Devdash::Models::SyncCursor.create!(source: "github", scope_key: "o/r", cursor_type: "updated_at", cursor_value: "2026-01-03T00:00:00Z")
    scope = Devdash::RepositoryScope.new(key: "r", repository_names: ["o/r"], label: "r", configuration_hash: "x")
    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 4) }).call(repository_scope: scope, since: nil)
  end

  it "preserves a successful repository run when a later repository fails" do
    client = instance_double(Devdash::Sources::Github::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    allow(client).to receive(:repository).and_return({ "default_branch" => "main" })
    allow(client).to receive(:updated_pull_numbers).and_return([])
    allow(client).to receive(:open_pull_numbers).and_return([])
    allow(client).to receive(:default_branch_commits).and_return([])
    allow(client).to receive(:page_count).and_return(0)
    calls = 0
    allow(writer).to receive(:call) do
      calls += 1
      raise StandardError, "later failed" if calls == 2

      :first
    end
    scope = Devdash::RepositoryScope.new(key: "all", repository_names: ["o/a", "o/b"], label: "all", configuration_hash: "x")

    expect { described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 2) }).call(repository_scope: scope, since: Time.utc(2026, 1, 1)) }
      .to raise_error(StandardError, "later failed")
    expect(calls).to eq(2)
  end

  it "uses source timestamps for observations and advances from the previous cursor" do
    client = instance_double(Devdash::Sources::Github::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    allow(client).to receive(:repository).and_return({ "default_branch" => "main", "updated_at" => "2026-01-02T00:00:00Z" })
    allow(client).to receive(:updated_pull_numbers).and_return([42])
    allow(client).to receive(:open_pull_numbers).and_return([])
    allow(client).to receive(:pull).and_return({ "number" => 42, "updated_at" => "2026-01-03T00:00:00Z", "state" => "open" })
    allow(client).to receive(:reviews).and_return([])
    allow(client).to receive(:timeline).and_return([])
    allow(client).to receive(:pull_files).and_return([])
    allow(client).to receive(:default_branch_commits).and_return([])
    allow(client).to receive(:page_count).and_return(1)
    expect(writer).to receive(:call) do |batch|
      pull = batch.observations.find { |observation| observation.entity_type == "pull_request" }
      expect(pull.source_updated_at).to eq(Time.utc(2026, 1, 3))
      expect(pull.observed_at).to eq(Time.utc(2026, 1, 4))
    end
    Devdash::Models::SyncCursor.create!(source: "github", scope_key: "o/r", cursor_type: "updated_at", cursor_value: "2026-01-03T00:00:00Z")
    scope = Devdash::RepositoryScope.new(key: "r", repository_names: ["o/r"], label: "r", configuration_hash: "x")
    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 4) }).call(repository_scope: scope, since: nil)
  end

  it "writes a real repository batch with immutable coverage" do
    client = instance_double(Devdash::Sources::Github::Client)
    allow(client).to receive(:repository).and_return({ "default_branch" => "main", "updated_at" => "2026-01-02T00:00:00Z" })
    allow(client).to receive(:updated_pull_numbers).and_return([42])
    allow(client).to receive(:open_pull_numbers).and_return([])
    allow(client).to receive(:pull).and_return({ "number" => 42, "node_id" => "pr-42", "state" => "open", "user" => { "login" => "dev" } })
    allow(client).to receive(:reviews).and_return([])
    allow(client).to receive(:timeline).and_return([])
    allow(client).to receive(:pull_files).and_return([])
    allow(client).to receive(:default_branch_commits).and_return([])
    allow(client).to receive(:page_count).and_return(6)
    scope = Devdash::RepositoryScope.new(key: "r", repository_names: ["o/r"], label: "r", configuration_hash: "x")

    run = described_class.new(client:, clock: -> { Time.utc(2026, 1, 2) }).call(repository_scope: scope, since: Time.utc(2026, 1, 1)).fetch(0)

    expect(run).to have_attributes(status: "succeeded", page_count: 6)
    expect(Devdash::Models::PullRequest.find_by(number: 42)).to be_present
    expect(run.coverages.where(scope_type: "repository", scope_key: "o/r").count).to eq(7)
  end
end
