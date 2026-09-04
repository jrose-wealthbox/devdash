# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/reporting/report_builder"

RSpec.describe Devdash::Reporting::ReportBuilder do
  before { connect_test_database! }

  let(:window) { Devdash::Metrics::Window.for("7d", end_at: Time.utc(2026, 9, 3)) }
  let(:scope) { Devdash::RepositoryScope.new(key: "crm-web", repository_names: ["acme/crm-web"], label: "crm-web", configuration_hash: "scope") }
  let!(:owner) { Devdash::Models::Person.create!(display_name: "John", owner: true) }
  let!(:peer) { Devdash::Models::Person.create!(display_name: "Peer") }

  Definition = Devdash::Metrics::Definition

  class FakeQuery
    attr_reader :calls

    def initialize(definition, values)
      @definition, @values, @calls = definition, values, []
    end

    attr_reader :definition

    def call(person:, window:, repository_scope:)
      @calls << [person.id, window.key, repository_scope.key]
      value = @values.fetch([person.id, window.key])
      Devdash::Metrics::Result.new(definition:, person_id: person.id, window:, repository_scope:, value:,
        sample_count: value || 0, breakdown: { repositories: { "acme/crm-web" => value } }, coverage: nil)
    end
  end

  class FakeRegistry
    attr_reader :entries

    Entry = Data.define(:query, :definition, :display_order)

    def initialize(entries)
      @entries = entries
    end
  end

  def definition(key:, role:, direction: "higher_better", section: "speed")
    Definition.new(key:, version: 1, name: key, description: "test", unit: "tickets", value_type: "count",
      signal_role: role, measurement_scope: "individual", collection_mode: "telemetry", directionality: direction,
      engthrive_section: section, framework_mappings: [{ framework: "space", dimension: "performance", status: "measured" }],
      required_coverage: [])
  end

  it "assembles current/previous owner values and peer comparisons without a composite score" do
    metric_definition = definition(key: "test.outcome", role: "outcome")
    query = FakeQuery.new(metric_definition, {
      [owner.id, "7d"] => 4, [owner.id, "7d"] => 4,
      [owner.id, "7d"] => 4, [owner.id, "7d"] => 4
    })
    # Window#previous has the same key, so distinguish calls by recording the
    # start timestamp in a small wrapper.
    query = Class.new(FakeQuery) do
      def call(person:, window:, repository_scope:)
        @calls << [person.id, window.start_at, repository_scope.key]
        value = person.id == 1 ? (window.start_at == Time.utc(2026, 8, 27) ? 4 : 3) : 2
        Devdash::Metrics::Result.new(definition:, person_id: person.id, window:, repository_scope:, value:,
          sample_count: value, breakdown: { repositories: { "acme/crm-web" => value } }, coverage: nil)
      end
    end.new(metric_definition, {})
    registry = FakeRegistry.new([FakeRegistry::Entry.new(query:, definition: metric_definition, display_order: 0)])
    cohort = Struct.new(:included_ids, :exclusions, :role, :level).new([peer.id], {}, "software_engineer", "senior")
    builder = described_class.new(registry:, cohort_resolver: instance_double("Cohort", call: cohort),
      cache: Devdash::Metrics::ReportCache.new, clock: -> { Time.utc(2026, 9, 3) })

    report = builder.call(owner:, window:, repository_scope: scope)

    row = report.section("speed").first
    expect(row[:current][:value]).to eq(4)
    expect(row[:previous][:value]).to eq(3)
    expect(row[:comparison][:absolute_delta]).to eq(1.0)
    expect(row).not_to have_key(:composite_score)
    expect(report.framework_coverage["space"]["status"]).to eq("measured")
  end

  it "does not interpret directionless activity or compare service/DORA metrics" do
    activity = definition(key: "test.activity", role: "activity", direction: "directionless")
    dora = Definition.new(key: "test.dora", version: 1, name: "DORA", description: "service", unit: "deployments",
      value_type: "count", signal_role: "outcome", measurement_scope: "service", collection_mode: "telemetry",
      directionality: "higher_better", engthrive_section: "quality",
      framework_mappings: [{ framework: "dora", dimension: "deployment_frequency", status: "planned" }], required_coverage: [])
    query = lambda do |person:, window:, repository_scope:|
      Devdash::Metrics::Result.new(definition: activity, person_id: person.id, window:, repository_scope:, value: 1, sample_count: 1, breakdown: {}, coverage: nil)
    end
    dora_query = lambda do |person:, window:, repository_scope:|
      Devdash::Metrics::Result.new(definition: dora, person_id: person.id, window:, repository_scope:, value: 1, sample_count: 1, breakdown: {}, coverage: nil)
    end
    entries = [FakeRegistry::Entry.new(query:, definition: activity, display_order: 0), FakeRegistry::Entry.new(query: dora_query, definition: dora, display_order: 0)]
    registry = FakeRegistry.new(entries)
    cohort = Struct.new(:included_ids, :exclusions, :role, :level).new([peer.id], {}, "software_engineer", "senior")

    report = described_class.new(registry:, cohort_resolver: instance_double("Cohort", call: cohort),
      cache: Devdash::Metrics::ReportCache.new).call(owner:, window:, repository_scope: scope)

    expect(report.section("speed").first[:comparison][:interpretation]).to be_nil
    expect(report.section("quality").first[:comparison][:status]).to eq("service_level_only")
  end
end
