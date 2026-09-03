# frozen_string_literal: true

require_relative "../../../lib/devdash/metrics/comparison"

RSpec.describe Devdash::Metrics::Comparison do
  let(:definition) do
    Devdash::Metrics::Definition.new(
      key: "test.count.v1", version: 1, name: "Test count", description: "A test count",
      unit: "items", value_type: "count", signal_role: "outcome", measurement_scope: "individual",
      collection_mode: "telemetry", directionality: "higher_better", engthrive_section: "speed",
      framework_mappings: [], required_coverage: []
    )
  end
  let(:scope) { Devdash::RepositoryScope.new(key: "all", repository_names: %w[o/a o/b], label: "All", configuration_hash: "scope") }
  let(:window) { Devdash::Metrics::Window.for("7d", end_at: Time.utc(2026, 9, 3)) }

  def result(person_id, value, current_window: window, breakdown: {})
    Devdash::Metrics::Result.new(definition:, person_id:, window: current_window, repository_scope: scope,
      value:, sample_count: value.nil? ? 0 : 1, breakdown:, coverage: nil)
  end

  it "aggregates people before calculating distribution statistics" do
    comparison = described_class.new(definition:).call(
      owner_id: 1,
      owner_result: result(1, 10),
      peer_results: [result(2, 0), result(3, 20), result(4, 30)]
    )

    expect(comparison.statistics.median).to eq(20.0)
    expect(comparison.statistics.p25).to eq(10.0)
    expect(comparison.statistics.p75).to eq(25.0)
    expect(comparison.owner_percentile).to be_within(0.000001).of(33.333333333333336)
    expect(comparison.difference_from_median).to eq(-10.0)
    expect(comparison.insufficient_peer_sample).to be(false)
  end

  it "returns deltas and suppresses percentile interpretation for directionless metrics" do
    directionless = definition.with(directionality: "directionless")
    current = result(1, 10)
    previous = result(1, 5, current_window: window.previous)
    comparison = described_class.new(definition: directionless).call(
      owner_id: 1, owner_result: current, peer_results: [result(2, 3), result(3, 5), result(4, 7)],
      previous_owner_result: previous
    )

    expect(comparison.absolute_delta).to eq(5.0)
    expect(comparison.percent_delta).to eq(100.0)
    expect(comparison.owner_percentile).to be_nil
    expect(comparison.interpretation).to be_nil
  end

  it "does not turn absent duration values into zeroes" do
    duration = definition.with(value_type: "duration", directionality: "lower_better")
    comparison = described_class.new(definition: duration).call(
      owner_id: 1, owner_result: result(1, 4),
      peer_results: [result(2, nil), result(3, 5), result(4, 7)]
    )

    expect(comparison.statistics.n).to eq(2)
    expect(comparison.insufficient_peer_sample).to be(true)
    expect(comparison.owner_percentile).to be_nil
  end
end
