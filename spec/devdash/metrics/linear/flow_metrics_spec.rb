# frozen_string_literal: true

require "spec_helper"
require_relative "fixture"
require_relative "../../../../lib/devdash/metrics/linear/queue_time"
require_relative "../../../../lib/devdash/metrics/linear/active_cycle_time"
require_relative "../../../../lib/devdash/metrics/linear/end_to_end_time"

RSpec.describe "Linear flow duration metrics" do
  include LinearMetricFixture

  before { build_linear_metric_fixture }

  it "reports queue time for issues first started in the window" do
    result = Devdash::Metrics::Linear::QueueTime.call(person: owner, window:, repository_scope: all_scope)

    expect(result.value).to eq(24.0)
    expect(result.sample_count).to eq(1)
    expect(result.breakdown[:samples]).to eq([24.0])
  end

  it "reports active cycle time with explicit pause subtraction and marks approximations" do
    result = Devdash::Metrics::Linear::ActiveCycleTime.call(person: owner, window:, repository_scope: all_scope)

    # CRM-101: 24h. CRM-104: 408h for the first completion and
    # 456h for the second after subtracting the explicit 24h reopen interval.
    expect(result.breakdown[:samples]).to contain_exactly(24.0, 408.0, 456.0)
    expect(result.value).to eq(408.0)
    expect(result.breakdown[:approximated_samples]).to eq(3)
  end

  it "reports end-to-end duration and excludes unavailable boundaries" do
    result = Devdash::Metrics::Linear::EndToEndTime.call(person: owner, window:, repository_scope: all_scope)

    expect(result.breakdown[:samples]).to contain_exactly(48.0, 432.0, 504.0)
    expect(result.value).to eq(432.0)
    expect(result.breakdown[:excluded]).to be_empty
  end

  it "keeps duration values at full precision" do
    @creator_differs.update!(created_at_source: Time.utc(2026, 8, 27, 0, 0, 0, 500_000), started_at_source: Time.utc(2026, 8, 28, 1, 0, 0, 250_000))

    result = Devdash::Metrics::Linear::QueueTime.call(person: owner, window:, repository_scope: all_scope)

    expect(result.breakdown[:samples].first).to be_within(0.000001).of(24.999930555555556)
    expect(result.breakdown[:samples].first).not_to be_a(Integer)
  end
end
