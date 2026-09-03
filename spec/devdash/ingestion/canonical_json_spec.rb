# frozen_string_literal: true

require "spec_helper"

RSpec.describe Devdash::Ingestion::CanonicalJson do
  it "sorts nested object keys without sorting arrays" do
    left = { "z" => [{ "b" => 2, "a" => 1 }], "a" => true }
    right = { "a" => true, "z" => [{ "a" => 1, "b" => 2 }] }

    expect(described_class.dump(left)).to eq(described_class.dump(right))
    expect(described_class.sha256(left)).to eq(described_class.sha256(right))
  end

  it "preserves array order" do
    expect(described_class.dump({ values: [2, 1] })).not_to eq(described_class.dump({ values: [1, 2] }))
  end
end
