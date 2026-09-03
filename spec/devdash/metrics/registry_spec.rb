# frozen_string_literal: true

require_relative "../../../lib/devdash/metrics/registry"

RSpec.describe Devdash::Metrics::Registry do
  let(:definition) do
    Devdash::Metrics::Definition.new(
      key: "test.count.v1", version: 1, name: "Test count", description: "A test count",
      unit: "items", value_type: "count", signal_role: "activity", measurement_scope: "individual",
      collection_mode: "telemetry", directionality: "directionless", engthrive_section: "speed",
      framework_mappings: [{ framework: "space", dimension: "activity", status: "measured" }],
      required_coverage: [["github", "test"]]
    )
  end
  let(:query) { Class.new { def self.call(**); end } }

  it "registers immutable definitions and fetches their query" do
    registry = described_class.new
    registry.register(query:, definition:)

    entry = registry.fetch("test.count.v1")
    expect(entry.definition).to eq(definition)
    expect(entry.query).to eq(query)
    expect { entry.definition.framework_mappings << {} }.to raise_error(FrozenError)
  end

  it "rejects duplicate keys and versions, and sorts definitions semantically" do
    registry = described_class.new
    registry.register(query:, definition:)
    expect { registry.register(query:, definition:) }.to raise_error(ArgumentError, /already registered/)

    quality = definition.with(key: "quality.metric.v1", engthrive_section: "quality")
    registry.register(query:, definition: quality)
    expect(registry.active_definitions.map(&:key)).to eq(["test.count.v1", "quality.metric.v1"])
  end

  it "requires a SPACE or DevEx mapping for applicable definitions" do
    no_mapping = definition.with(framework_mappings: [])
    expect { described_class.new.register(query:, definition: no_mapping) }.to raise_error(ArgumentError, /framework mapping/)
  end
end
