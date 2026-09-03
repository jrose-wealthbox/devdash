# frozen_string_literal: true

require_relative "../../../lib/devdash/metrics/report_cache"

RSpec.describe Devdash::Metrics::ReportCache do
  before { connect_test_database! }

  let(:window) { Devdash::Metrics::Window.for("7d", end_at: Time.utc(2026, 9, 3)) }
  let(:scope) { Devdash::RepositoryScope.new(key: "crm-web", repository_names: ["o/crm-web"], label: "crm-web", configuration_hash: "scope-v1") }
  let(:cache) { described_class.new(format_version: 1) }

  def key_options(metric_version: 1, source_watermark: "watermark-v1")
    { window:, repository_scope: scope, cohort_hash: "cohort-v1",
      metric_definitions: [{ key: "test.v1", version: metric_version }], source_watermark_hash: source_watermark }
  end

  it "writes and reads snapshots by a semantic canonical key" do
    snapshot = cache.write(**key_options, structured: { "value" => 3 }, rendered_text: "value: 3")

    expect(cache.fetch(**key_options)).to eq(snapshot)
    expect(snapshot.structured).to eq("value" => 3)
    expect(snapshot.cache_key).to match(/\A[0-9a-f]{64}\z/)
  end

  it "misses when an observation watermark or definition version changes" do
    cache.write(**key_options, structured: {})

    expect(cache.fetch(**key_options(source_watermark: "watermark-v2"))).to be_nil
    expect(cache.fetch(**key_options(metric_version: 2))).to be_nil
  end

  it "clears only report snapshots" do
    organization = Devdash::Models::Organization.create!(name: "Keep")
    cache.write(**key_options, structured: {})
    cache.clear!

    expect(Devdash::Models::ReportSnapshot.count).to eq(0)
    expect(Devdash::Models::Organization.find(organization.id)).to be_present
  end
end
