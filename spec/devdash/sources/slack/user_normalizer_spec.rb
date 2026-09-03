require "spec_helper"
require "json"
require_relative "../../../../lib/devdash/sources/slack/user_normalizer"

RSpec.describe Devdash::Sources::Slack::UserNormalizer do
  before do
    connect_test_database!
  end

  def source_record(payload, observed_at: Time.utc(2026, 9, 3, 12))
    Devdash::Models::SourceRecord.new(payload_json: JSON.generate(payload), observed_at: observed_at)
  end

  it "creates an unresolved identity without requiring email and does not merge display names" do
    first = { "id" => "U006", "name" => "one", "real_name" => "Same Name", "profile" => { "display_name" => "Same", "real_name" => "Same Name", "title" => "Engineer" }, "deleted" => false }
    second = first.merge("id" => "U007")
    described_class.call(source_record(first))
    described_class.call(source_record(second))

    expect(Devdash::Models::Person.count).to eq(2)
    expect(Devdash::Models::SourceIdentity.where(source: "slack").count).to eq(2)
    expect(Devdash::Models::SourceIdentity.where(external_id: "U006").first.normalized_email).to be_nil
  end

  it "sets lifecycle flags from Slack fields and records the exact profile title" do
    payload = { "id" => "U003", "real_name" => "Build Bot", "deleted" => true, "is_bot" => true, "is_restricted" => true,
                "profile" => { "display_name" => "Build", "title" => "Automation" } }
    described_class.call(source_record(payload))
    person = Devdash::Models::Person.first

    expect(person).to have_attributes(active: false, human: false, bot: true, guest: true)
    expect(person.role_assignments.first).to have_attributes(original_title: "Automation", normalized_role: "unknown", normalized_level: "unknown")
  end

  it "closes an old title assignment when the observed title changes" do
    first = { "id" => "U001", "real_name" => "Alex", "profile" => { "display_name" => "Alex", "title" => "Engineer" } }
    second = first.merge("profile" => { "display_name" => "Alex", "title" => "Staff Engineer" })
    described_class.call(source_record(first, observed_at: Time.utc(2026, 9, 1)))
    described_class.call(source_record(second, observed_at: Time.utc(2026, 9, 3)))

    expect(Devdash::Models::RoleAssignment.order(:effective_from).map(&:original_title)).to eq(["Engineer", "Staff Engineer"])
    expect(Devdash::Models::RoleAssignment.first.effective_until).to eq(Time.utc(2026, 9, 3))
    expect(Devdash::Models::RoleAssignment.last.effective_until).to be_nil
  end
end
