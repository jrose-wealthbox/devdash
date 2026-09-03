# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/fake_normalizer"

RSpec.describe Devdash::Ingestion::Writer do
  before do
    connect_test_database!
    FakeNormalizer.reset!
    Devdash::Normalizers::Registry.clear!
    Devdash::Normalizers::Registry.register(
      source: "fake", entity_type: "thing", normalizer: FakeNormalizer
    )
  end

  let(:writer) { described_class.new }
  let(:batch) do
    Devdash::Ingestion::Batch.new(
      source: "fake", scope_key: "global", cursor_type: "opaque",
      cursor_before: nil, cursor_after: "cursor-1",
      observations: [observation("one")], coverages: [], page_count: 1, retry_count: 0
    )
  end

  def observation(id)
    Devdash::Ingestion::SourceObservation.new(
      entity_type: "thing", external_id: id, source_updated_at: nil,
      observed_at: Time.utc(2026, 9, 3, 12), api_version: "v1",
      query_fingerprint: "query", payload: { "id" => id, "nested" => { "z" => 1, "a" => 2 } }
    )
  end

  it "writes one canonical fact and two successful runs for repeated ingestion" do
    writer.call(batch)
    writer.call(batch.with(cursor_before: "cursor-1"))

    expect(Devdash::Models::SourceRecord.count).to eq(1)
    expect(Devdash::Models::CollectorRun.where(status: "succeeded").count).to eq(2)
    expect(FakeNormalizer.calls).to eq(["one"])
    expect(Devdash::Models::SyncCursor.find_by(source: "fake", scope_key: "global").cursor_value).to eq("cursor-1")
  end

  it "rolls back records and cursor while retaining a sanitized failed run" do
    failing_batch = batch.with(observations: [observation("two"), observation("three")])
    FakeNormalizer.raise_on_external_id = "three"

    expect { writer.call(failing_batch) }.to raise_error(FakeNormalizer::Failure)
    expect(Devdash::Models::SyncCursor.find_by(source: "fake", scope_key: "global")).to be_nil
    expect(Devdash::Models::SourceRecord.where(external_id: %w[two three])).to be_empty
    expect(Devdash::Models::CollectorRun.order(:id).last.status).to eq("failed")
    expect(Devdash::Models::CollectorRun.order(:id).last.error_message).not_to include("access_token")
  end

  it "rejects a stale cursor before writing" do
    Devdash::Models::SyncCursor.create!(source: "fake", scope_key: "global", cursor_type: "opaque", cursor_value: "current")
    stale = batch.with(cursor_before: "old")

    expect { writer.call(stale) }.to raise_error(Devdash::Ingestion::StaleCursorError)
    expect(Devdash::Models::SourceRecord.count).to eq(0)
    expect(Devdash::Models::CollectorRun.order(:id).last.status).to eq("failed")
  end

  it "rejects secret-like payload keys" do
    expect {
      observation("secret").with(payload: { "Authorization" => "Bearer secret" })
    }.to raise_error(ArgumentError)
  end

  it "rejects nested secret-like payload keys" do
    expect {
      Devdash::Ingestion::SourceObservation.new(
        entity_type: "thing", external_id: "nested-secret", source_updated_at: nil,
        observed_at: Time.utc(2026, 9, 3, 12), api_version: "v1",
        query_fingerprint: "query", payload: { "metadata" => [{ "X-API-KEY" => "secret" }] }
      )
    }.to raise_error(ArgumentError)
  end

  it "preserves explicit coverage scope fields" do
    scoped_batch = batch.with(
      coverages: [{ scope_type: "repository", scope_key: "crm-web", entity_type: "thing", status: "complete" }]
    )

    writer.call(scoped_batch)

    coverage = Devdash::Models::CollectorRunCoverage.last
    expect(coverage.scope_type).to eq("repository")
    expect(coverage.scope_key).to eq("crm-web")
  end

  it "owns immutable nested observations and coverages" do
    payload_key = +"payload-key"
    payload_value = +"before"
    payload = { payload_key => [{ "value" => payload_value }] }
    coverage_scope = +"crm-web"
    coverage_repo = +"crm-web"
    coverage = { scope_type: "repository", scope_key: coverage_scope, entity_type: "thing", status: "complete",
                 metadata: { "repos" => [coverage_repo] } }
    observation_value = observation("owned").with(payload: payload)
    owned_batch = batch.with(observations: [observation_value], coverages: [coverage])

    payload_value.replace("after")
    payload_key.replace("changed-key")
    coverage_repo.replace("other-repo")
    coverage_scope.replace("other-repo")

    expect(owned_batch.observations).to be_frozen
    expect(owned_batch.coverages).to be_frozen
    expect(owned_batch.observations.first.payload["payload-key"][0]["value"]).to eq("before")
    expect(owned_batch.observations.first.payload["payload-key"][0]["value"]).to be_frozen
    expect(owned_batch.observations.first.payload.keys).to eq(["payload-key"])
    expect(owned_batch.observations.first.payload.keys.first).to be_frozen
    expect(owned_batch.coverages.first[:metadata]["repos"]).to eq(["crm-web"])
    expect(owned_batch.coverages.first[:scope_key]).to eq("crm-web")
    expect(owned_batch.coverages.first[:scope_key]).to be_frozen
    expect(owned_batch.coverages.first[:metadata]["repos"].first).to be_frozen
  end

  it "rejects a cursor race between validation and atomic advancement" do
    Devdash::Models::SyncCursor.create!(
      source: "fake", scope_key: "global", cursor_type: "opaque", cursor_value: "cursor-0"
    )
    raced_batch = batch.with(cursor_before: "cursor-0", cursor_after: "cursor-1")
    allow(writer).to receive(:verify_cursor!).and_wrap_original do |original, candidate|
      original.call(candidate)
      Devdash::Models::SyncCursor.find_by!(source: "fake", scope_key: "global").update!(cursor_value: "raced")
    end

    expect { writer.call(raced_batch) }.to raise_error(Devdash::Ingestion::StaleCursorError)
    expect(Devdash::Models::SourceRecord.count).to eq(0)
    # The simulated competing update is part of the transaction and therefore
    # rolls back with the failed ingestion; the original cursor remains intact.
    expect(Devdash::Models::SyncCursor.find_by!(source: "fake", scope_key: "global").cursor_value).to eq("cursor-0")
    expect(Devdash::Models::CollectorRun.order(:id).last.status).to eq("failed")
  end
end
