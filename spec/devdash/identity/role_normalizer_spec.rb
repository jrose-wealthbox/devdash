# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/identity/manual_configuration"
require_relative "../../../lib/devdash/identity/role_normalizer"

RSpec.describe Devdash::Identity::RoleNormalizer do
  before { connect_test_database! }

  def configuration(yaml)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "people.yml")
      File.write(path, yaml)
      return Devdash::Identity::ManualConfiguration.load(path:, repository_aliases: ["app"])
    end
  end

  it "applies a configured manual role and level without inferring from activity" do
    config = configuration(<<~YAML)
      owner: john
      people:
        john:
          role: platform_engineer
          level: principal
    YAML
    person = Devdash::Models::Person.create!(display_name: "John", owner: true)
    result = described_class.new(configuration: config).call(person:, title: "Anything", source: "slack",
      effective_from: Time.utc(2026, 9, 1), observed_at: Time.utc(2026, 9, 3))

    expect(result).to have_attributes(role: "platform_engineer", level: "principal", rule_id: "manual:john")
    expect(person.role_assignments.first).to have_attributes(original_title: "Anything", normalized_role: "platform_engineer", normalized_level: "principal")
  end

  it "uses ordered regex rules, conservative built-ins, and unknowns" do
    config = configuration(<<~YAML)
      owner: john
      people:
        john: {}
      role_rules:
        - id: staff-rule
          pattern: '(?i)staff.*engineer'
          role: software_engineer
          level: staff
    YAML
    normalizer = described_class.new(configuration: config)
    person = Devdash::Models::Person.create!(display_name: "John", owner: true)

    expect(normalizer.call(person:, title: "Staff Engineer", effective_from: Time.utc(2026, 9, 1), observed_at: Time.utc(2026, 9, 2))).to have_attributes(
      role: "software_engineer", level: "staff", rule_id: "staff-rule"
    )
    expect(normalizer.call(person:, title: "Product Manager", effective_from: Time.utc(2026, 9, 2), observed_at: Time.utc(2026, 9, 3))).to have_attributes(
      role: "unknown", level: "unknown"
    )
  end

  it "closes and opens assignments only when normalized classification changes" do
    config = configuration("owner: john\npeople:\n  john: {}\n")
    person = Devdash::Models::Person.create!(display_name: "John", owner: true)
    normalizer = described_class.new(configuration: config)
    normalizer.call(person:, title: "Senior Software Engineer", effective_from: Time.utc(2026, 9, 1), observed_at: Time.utc(2026, 9, 1))
    normalizer.call(person:, title: "Sr. Software Engineer", effective_from: Time.utc(2026, 9, 2), observed_at: Time.utc(2026, 9, 2))
    normalizer.call(person:, title: "Engineering Manager", effective_from: Time.utc(2026, 9, 3), observed_at: Time.utc(2026, 9, 3))

    expect(person.role_assignments.count).to eq(2)
    expect(person.role_assignments.order(:effective_from).first.effective_until).to eq(Time.utc(2026, 9, 3))
    expect(person.role_assignments.order(:effective_from).map(&:normalized_level)).to eq(["senior", "unknown"])
  end
end
