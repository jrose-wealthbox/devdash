# frozen_string_literal: true

require_relative "../../../lib/devdash/metrics/window"
require_relative "../../../lib/devdash/metrics/weekday_normalizer"

RSpec.describe Devdash::Metrics::WeekdayNormalizer do
  it "counts weekday overlap for partial days" do
    window = Devdash::Metrics::Window.new(
      key: "custom", start_at: Time.utc(2026, 9, 3, 12), end_at: Time.utc(2026, 9, 4, 12)
    )

    expect(described_class.equivalent_days(window)).to eq(1.0)
  end

  it "skips weekend seconds and spans arbitrary windows" do
    window = Devdash::Metrics::Window.new(
      key: "custom", start_at: Time.utc(2026, 9, 4, 12), end_at: Time.utc(2026, 9, 7, 12)
    )

    expect(described_class.call(window)).to eq(1.0)
  end

  it "supports seven, thirty, and one hundred eighty day windows" do
    end_at = Time.utc(2026, 9, 3, 12)
    expect(described_class.equivalent_days(Devdash::Metrics::Window.for("7d", end_at:))).to eq(5.0)
    expect(described_class.equivalent_days(Devdash::Metrics::Window.for("30d", end_at:))).to eq(22.0)
    expect(described_class.equivalent_days(Devdash::Metrics::Window.for("180d", end_at:))).to eq(128.5)
  end

  it "returns nil only for an empty interval" do
    window = Devdash::Metrics::Window.new(
      key: "empty", start_at: Time.utc(2026, 1, 1), end_at: Time.utc(2026, 1, 1)
    )
    expect(described_class.call(window)).to be_nil
  end
end
