# frozen_string_literal: true

require "devdash/reprocessing/reprocessor"
require_relative "../../support/fake_normalizer"

RSpec.describe Devdash::Reprocessing::Reprocessor do
  before do
    connect_test_database!
    FakeNormalizer.reset!
    Devdash::Normalizers::Registry.clear!
  end

  def source_record(id, observed_at:, source_updated_at: nil, version: nil)
    run = Devdash::Models::CollectorRun.create!(source: "test", scope_key: "all", status: "succeeded", started_at: observed_at)
    Devdash::Models::SourceRecord.create!(collector_run: run, source: "test", scope_key: "all", entity_type: "thing",
      external_id: id, observed_at: observed_at, source_updated_at: source_updated_at,
      query_fingerprint: "q", payload_hash: "#{id}-#{observed_at.to_i}", payload_json: "{}", normalizer_version: version)
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

  it "rebuilds only injected disposable cache models" do
    cache = double("cache", delete_all: 3)
    expect(cache).to receive(:delete_all)
    expect(Devdash::Reprocessing::DerivedRebuilder.new(cache_models: [cache]).call).to eq(3)
  end
end
