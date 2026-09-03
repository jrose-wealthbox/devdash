# frozen_string_literal: true

require_relative "../../../lib/devdash/metrics/window"

RSpec.describe Devdash::Metrics::Window do
  let(:end_at) { Time.utc(2026, 9, 3, 12, 0, 0) }

  it "creates adjacent half-open current and previous windows" do
    window = described_class.for("7d", end_at: end_at)

    expect(window.start_at).to eq(Time.utc(2026, 8, 27, 12))
    expect(window.end_at).to eq(end_at)
    expect(window.previous).to eq(described_class.new(
      key: "7d", start_at: Time.utc(2026, 8, 20, 12), end_at: Time.utc(2026, 8, 27, 12)
    ))
  end

  it "accepts the start boundary and excludes the end boundary" do
    window = described_class.for("30d", end_at: end_at)

    expect(window.include?(window.start_at)).to be(true)
    expect(window.include?(window.end_at - 1)).to be(true)
    expect(window.include?(window.end_at)).to be(false)
  end

  it "normalizes boundaries to UTC and rejects unsupported windows" do
    local = Time.new(2026, 9, 3, 8, 0, 0, "-04:00")
    expect(described_class.for("180d", end_at: local).end_at).to eq(local.utc)
    expect { described_class.for("1d", end_at:) }.to raise_error(ArgumentError, /unsupported window/)
  end
end
