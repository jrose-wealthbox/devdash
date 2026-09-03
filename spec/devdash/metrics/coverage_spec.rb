# frozen_string_literal: true

require_relative "../../../lib/devdash/metrics/coverage"

RSpec.describe Devdash::Metrics::Coverage do
  before { connect_test_database! }

  let(:window) { Devdash::Metrics::Window.for("7d", end_at: Time.utc(2026, 9, 3)) }
  let(:scope) { Devdash::RepositoryScope.new(key: "all", repository_names: %w[o/a o/b], label: "All", configuration_hash: "scope") }
  let(:definition) do
    Devdash::Metrics::Definition.new(
      key: "test.v1", version: 1, name: "Test", description: "Test", unit: "items", value_type: "count",
      signal_role: "activity", measurement_scope: "individual", collection_mode: "telemetry",
      directionality: "directionless", engthrive_section: "speed", framework_mappings: [],
      required_coverage: [{ source: "github", entity_type: "pull_request", scope: "repository" }]
    )
  end

  def coverage(repo, start_at: window.start_at, end_at: window.end_at, status: "complete", source: "github", entity_type: "pull_request")
    run = Devdash::Models::CollectorRun.create!(source:, scope_key: repo, status: "succeeded", started_at: end_at - 10,
      finished_at: end_at)
    run.coverages.create!(scope_type: "repository", scope_key: repo, entity_type:, requested_start_at: start_at,
      requested_end_at: end_at, achieved_start_at: start_at, achieved_end_at: end_at, status:)
  end

  it "marks all-repository coverage partial and identifies only the missing repository" do
    coverage("o/a")

    result = described_class.new.call(definition:, window:, repository_scope: scope)

    expect(result.status).to eq("partial")
    expect(result.affected_repositories).to eq(["o/b"])
  end

  it "evaluates global requirements once rather than per repository" do
    global = definition.with(required_coverage: [{ source: "linear", entity_type: "linear_issue", scope: "global" }])
    coverage("global", source: "linear", entity_type: "linear_issue")
    Devdash::Models::CollectorRunCoverage.last.update!(scope_type: "global", scope_key: "global")

    result = described_class.new.call(definition: global, window:, repository_scope: scope)
    expect(result.status).to eq("complete")
    expect(result.affected_repositories).to eq([])
  end

  it "distinguishes stale historical coverage from absent coverage" do
    coverage("o/a", start_at: window.start_at + 1.day)
    result = described_class.new.call(definition:, window:, repository_scope: Devdash::RepositoryScope.new(
      key: "crm", repository_names: ["o/a"], label: "crm", configuration_hash: "crm"
    ))

    expect(result.status).to eq("partial")
    expect(result.reasons.join(" ")).to match(/historical|before/)
    expect(result.last_success_timestamps).not_to be_empty
  end
end
