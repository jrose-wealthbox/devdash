# frozen_string_literal: true

require "devdash/reprocessing/reprocessor"
require "devdash/sources/linear/normalizer"
require "open3"
require "rbconfig"
require_relative "../../support/fake_normalizer"

RSpec.describe Devdash::Reprocessing::Reprocessor do
  it "loads its Active Record base when required without the central loader" do
    lib_directory = File.expand_path("../../../lib", __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{lib_directory}", "-e",
      'require "devdash/reprocessing/reprocessor"; abort unless Devdash::Models::BaseRecord.abstract_class?'
    )

    expect(status).to be_success, "stdout: #{stdout}\nstderr: #{stderr}"
  end

  it "registers Linear normalizers when loaded before the reprocessor" do
    lib_directory = File.expand_path("../../../lib", __dir__)
    script = <<~'RUBY'
      require "devdash/sources/linear/normalizer"
      require "devdash/reprocessing/reprocessor"

      registry = Devdash::Normalizers::Registry
      normalizer = Devdash::Sources::Linear::NORMALIZER
      %w[linear_issue linear_issue_history].each do |entity_type|
        abort "missing Linear normalizer" unless registry.fetch(source: "linear", entity_type:).equal?(normalizer)
      end

      Devdash::Reprocessing::Reprocessor.new(registry: registry)
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I#{lib_directory}", "-e", script)

    expect(status).to be_success, "stdout: #{stdout}\nstderr: #{stderr}"
  end

  before do
    connect_test_database!
    FakeNormalizer.reset!
    Devdash::Normalizers::Registry.clear!
  end

  def source_record(id, observed_at:, source_updated_at: nil, version: nil, entity_type: "thing", payload: {}, source: "test")
    run = Devdash::Models::CollectorRun.create!(source:, scope_key: "all", status: "succeeded", started_at: observed_at)
    payload_json = Devdash::Ingestion::CanonicalJson.dump(payload)
    Devdash::Models::SourceRecord.create!(collector_run: run, source:, scope_key: "all", entity_type:,
      external_id: id, observed_at: observed_at, source_updated_at: source_updated_at,
      query_fingerprint: "q", payload_hash: Devdash::Ingestion::CanonicalJson.sha256(payload), payload_json:, normalizer_version: version)
  end

  it "resets and replays evidence in deterministic observation order" do
    source_record("later", observed_at: Time.utc(2026, 1, 3), source_updated_at: Time.utc(2026, 1, 2))
    source_record("earlier", observed_at: Time.utc(2026, 1, 2), source_updated_at: Time.utc(2026, 1, 1))
    Devdash::Normalizers::Registry.register(source: "test", entity_type: "thing", normalizer: FakeNormalizer)

    expect {
      described_class.new(registry: Devdash::Normalizers::Registry).call
    }.to change(Devdash::Models::NormalizationRun, :count).by(1)

    expect(FakeNormalizer.calls).to eq(["earlier", "later"])
    expect(Devdash::Models::SourceRecord.pluck(:normalizer_version).uniq).to eq([1])
    expect(Devdash::Models::NormalizationRun.last).to have_attributes(status: "succeeded", input_count: 2)
  end

  it "rolls back canonical changes but records a failed run" do
    source_record("good", observed_at: Time.utc(2026, 1, 1), version: 1)
    source_record("bad", observed_at: Time.utc(2026, 1, 2), version: 1)
    failing_normalizer = Class.new do
      define_singleton_method(:version) { 2 }
      define_singleton_method(:reset!) { }
      define_singleton_method(:call) do |record|
        raise FakeNormalizer::Failure, "normalizer failed" if record.external_id == "bad"
      end
    end
    Devdash::Normalizers::Registry.register(source: "test", entity_type: "thing", normalizer: failing_normalizer)

    expect { described_class.new(registry: Devdash::Normalizers::Registry).call }.to raise_error(FakeNormalizer::Failure)

    expect(Devdash::Models::SourceRecord.where(normalizer_version: 1).count).to eq(2)
    expect(Devdash::Models::NormalizationRun.last).to have_attributes(status: "failed", error_class: "FakeNormalizer::Failure")
  end

  it "marks every replay run failed when a later normalizer fails" do
    source_record("thing", observed_at: Time.utc(2026, 1, 1), version: 1)
    source_record("other", observed_at: Time.utc(2026, 1, 2), version: 1)
    first = Class.new do
      define_singleton_method(:version) { 2 }
      define_singleton_method(:reset!) { }
      define_singleton_method(:call) { |_record| }
    end
    second_failure = Class.new(StandardError)
    second = Class.new do
      define_singleton_method(:version) { 3 }
      define_singleton_method(:reset!) { }
      define_singleton_method(:call) { |_record| raise second_failure, "authorization=secret" }
    end
    Devdash::Normalizers::Registry.register(source: "test", entity_type: "first", normalizer: first)
    Devdash::Normalizers::Registry.register(source: "test", entity_type: "thing", normalizer: second)

    expect { described_class.new(registry: Devdash::Normalizers::Registry).call }.to raise_error(second_failure)

    expect(Devdash::Models::NormalizationRun.pluck(:status)).to all(eq("failed"))
    expect(Devdash::Models::NormalizationRun.pluck(:error_message)).to all(include("authorization=[REDACTED]"))
    expect(Devdash::Models::SourceRecord.pluck(:normalizer_version).uniq).to eq([1])
  end

  it "marks all runs failed when the derived rebuilder fails" do
    source_record("thing", observed_at: Time.utc(2026, 1, 1), version: 1)
    Devdash::Normalizers::Registry.register(source: "test", entity_type: "thing", normalizer: FakeNormalizer)
    rebuilder = double("derived rebuilder")
    allow(rebuilder).to receive(:call).and_raise(StandardError, "token=secret")

    expect { described_class.new(registry: Devdash::Normalizers::Registry, derived_rebuilder: rebuilder).call }
      .to raise_error(StandardError)

    expect(Devdash::Models::NormalizationRun.pluck(:status)).to eq(["failed"])
    expect(Devdash::Models::NormalizationRun.last.error_message).to include("token=[REDACTED]")
  end

  it "rebuilds only injected disposable cache models" do
    cache = double("cache", delete_all: 3, disposable_derived_cache?: true)
    expect(cache).to receive(:delete_all)
    expect(Devdash::Reprocessing::DerivedRebuilder.new(cache_models: [cache]).call).to eq(3)
  end

  it "resets one shared normalizer once when it owns multiple entity types" do
    source_record("issue", observed_at: Time.utc(2026, 1, 1), entity_type: "issue")
    source_record("history", observed_at: Time.utc(2026, 1, 1), entity_type: "history")
    calls = []
    normalizer = Class.new do
      define_singleton_method(:version) { 1 }
      define_singleton_method(:reset!) { calls << :reset }
      define_singleton_method(:call) { |record| calls << record.entity_type }
    end
    Devdash::Normalizers::Registry.register(source: "test", entity_type: "issue", normalizer:)
    Devdash::Normalizers::Registry.register(source: "test", entity_type: "history", normalizer:)

    described_class.new(registry: Devdash::Normalizers::Registry).call

    expect(calls).to eq([:reset, "history", "issue"])
    expect(Devdash::Models::NormalizationRun.count).to eq(1)
  end

  it "replays a shared Linear issue and history normalizer into both canonical tables" do
    issue_payload = {
      "id" => "issue-1", "identifier" => "ENG-1", "title" => "Issue",
      "updatedAt" => "2026-01-02T00:00:00Z", "createdAt" => "2026-01-01T00:00:00Z",
      "state" => { "id" => "state-1", "name" => "Todo", "type" => "backlog" },
      "creator" => nil, "assignee" => nil, "labels" => { "nodes" => [] }, "attachments" => { "nodes" => [] }
    }
    history_payload = { "issue_id" => "issue-1", "history" => [{ "id" => "history-1", "createdAt" => "2026-01-02T01:00:00Z", "actor" => nil, "fromState" => { "name" => "Todo" }, "toState" => { "name" => "In Progress" } }] }
    source_record("issue", observed_at: Time.utc(2026, 1, 2), entity_type: "linear_issue", payload: issue_payload, source: "linear")
    source_record("history", observed_at: Time.utc(2026, 1, 2), entity_type: "linear_issue_history", payload: history_payload, source: "linear")
    Devdash::Normalizers::Registry.register(source: "linear", entity_type: "linear_issue", normalizer: Devdash::Sources::Linear::NORMALIZER)
    Devdash::Normalizers::Registry.register(source: "linear", entity_type: "linear_issue_history", normalizer: Devdash::Sources::Linear::NORMALIZER)

    described_class.new(registry: Devdash::Normalizers::Registry).call

    expect(Devdash::Models::LinearIssue.count).to eq(1)
    expect(Devdash::Models::LinearIssueEvent.pluck(:stable_external_id)).to eq(["history-1"])
  end

  it "replays Linear issues before history even when registry entries are reversed" do
    issue_payload = {
      "id" => "issue-1", "identifier" => "ENG-1", "title" => "Issue",
      "updatedAt" => "2026-01-02T00:00:00Z", "createdAt" => "2026-01-01T00:00:00Z",
      "state" => { "id" => "state-1", "name" => "Todo", "type" => "backlog" },
      "creator" => nil, "assignee" => nil, "labels" => { "nodes" => [] }, "attachments" => { "nodes" => [] }
    }
    history_payload = { "issue_id" => "issue-1", "history" => [{ "id" => "history-1", "createdAt" => "2026-01-02T01:00:00Z", "actor" => nil }] }
    source_record("issue", observed_at: Time.utc(2026, 1, 2), entity_type: "linear_issue", payload: issue_payload, source: "linear")
    source_record("history", observed_at: Time.utc(2026, 1, 2), entity_type: "linear_issue_history", payload: history_payload, source: "linear")
    Devdash::Normalizers::Registry.register(source: "linear", entity_type: "linear_issue_history", normalizer: Devdash::Sources::Linear::NORMALIZER)
    Devdash::Normalizers::Registry.register(source: "linear", entity_type: "linear_issue", normalizer: Devdash::Sources::Linear::NORMALIZER)

    expect { described_class.new(registry: Devdash::Normalizers::Registry).call }.not_to raise_error
    expect(Devdash::Models::LinearIssueEvent.pluck(:stable_external_id)).to eq(["history-1"])
  end

  it "rejects an unmarked cache model before opening a transaction" do
    cache = double("canonical model", delete_all: 3)
    expect(ActiveRecord::Base).not_to receive(:transaction)

    expect { Devdash::Reprocessing::DerivedRebuilder.new(cache_models: [cache]).call }
      .to raise_error(ArgumentError, /disposable derived cache/)
  end
end
