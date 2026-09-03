# frozen_string_literal: true

require_relative "../../../lib/devdash/metrics/statistics"

RSpec.describe Devdash::Metrics::Statistics do
  it "uses linear interpolation for quartiles" do
    summary = described_class.call([1, 2, 3, 4])

    expect(summary.n).to eq(4)
    expect(summary.p25).to eq(1.75)
    expect(summary.median).to eq(2.5)
    expect(summary.p75).to eq(3.25)
    expect(summary.iqr).to eq(1.5)
  end

  it "handles odd collections, duplicates, and missing observations" do
    summary = described_class.call([nil, 1, 1, 5, 9])

    expect(summary.n).to eq(4)
    expect(summary.median).to eq(3.0)
    expect(summary.p25).to eq(1.0)
    expect(summary.p75).to eq(6.0)
  end

  it "returns an empty summary for no observations" do
    expect(described_class.call([]).median).to be_nil
  end
end
