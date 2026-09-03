require "spec_helper"
require "json"
require_relative "../../../../lib/devdash/sources/slack/user_normalizer"

RSpec.describe Devdash::Sources::Slack::UserNormalizer do
  before do
    connect_test_database!
  end

  def source_record(payload, observed_at: Time.utc(2026, 9, 3, 12), source_updated_at: nil)
    Devdash::Models::SourceRecord.new(
      payload_json: JSON.generate(payload), observed_at: observed_at, source_updated_at: source_updated_at
    )
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

  it "uses the source update timestamp for role assignment effective dates" do
    first = { "id" => "U001", "name" => "alex-owner", "profile" => { "display_name" => "Alex", "title" => "Engineer" } }
    second = first.merge("profile" => { "display_name" => "Alex", "title" => "Staff Engineer" })
    first_effective_at = Time.utc(2026, 8, 30, 9)
    second_effective_at = Time.utc(2026, 9, 2, 9)

    described_class.call(source_record(first, observed_at: Time.utc(2026, 9, 1, 12), source_updated_at: first_effective_at))
    described_class.call(source_record(second, observed_at: Time.utc(2026, 9, 3, 12), source_updated_at: second_effective_at))

    assignments = Devdash::Models::RoleAssignment.order(:effective_from)
    expect(assignments.map(&:effective_from)).to eq([first_effective_at, second_effective_at])
    expect(assignments.first.effective_until).to eq(second_effective_at)
    expect(assignments.map(&:observed_at)).to eq([Time.utc(2026, 9, 1, 12), Time.utc(2026, 9, 3, 12)])
  end

  it "closes the current title assignment when Slack removes the title" do
    first = { "id" => "U001", "name" => "alex-owner", "profile" => { "display_name" => "Alex", "title" => "Engineer" } }
    removed = first.merge("profile" => { "display_name" => "Alex", "title" => "" })
    effective_at = Time.utc(2026, 9, 2, 9)

    described_class.call(source_record(first, source_updated_at: Time.utc(2026, 9, 1, 9)))
    described_class.call(source_record(removed, observed_at: Time.utc(2026, 9, 3, 12), source_updated_at: effective_at))

    assignment = Devdash::Models::RoleAssignment.first
    expect(Devdash::Models::RoleAssignment.count).to eq(1)
    expect(assignment.effective_until).to eq(effective_at)
  end

  it "initializes first observation and login and preserves first observation on updates" do
    payload = { "id" => "U001", "name" => "alex-owner", "profile" => { "display_name" => "Alex" } }
    first_observed_at = Time.utc(2026, 9, 1, 12)
    second_observed_at = Time.utc(2026, 9, 3, 12)

    described_class.call(source_record(payload, observed_at: first_observed_at))
    identity = Devdash::Models::SourceIdentity.find_by!(source: "slack", external_id: "U001")
    expect(identity).to have_attributes(login: "alex-owner", first_observed_at: first_observed_at, last_observed_at: first_observed_at)

    described_class.call(source_record(payload, observed_at: second_observed_at))

    expect(identity.reload).to have_attributes(first_observed_at: first_observed_at, last_observed_at: second_observed_at)
  end

  it "preserves a manually resolved identity on later observations" do
    payload = { "id" => "U001", "name" => "alex-owner", "profile" => { "display_name" => "Alex" } }
    described_class.call(source_record(payload))
    identity = Devdash::Models::SourceIdentity.find_by!(source: "slack", external_id: "U001")
    identity.update!(resolution_method: "manual")

    described_class.call(source_record(payload, observed_at: Time.utc(2026, 9, 4, 12)))

    expect(identity.reload.resolution_method).to eq("manual")
  end

  it "preserves a manually resolved Slack-only person and identity during reset" do
    payload = { "id" => "U001", "name" => "alex-owner", "profile" => { "display_name" => "Alex" } }
    person = described_class.call(source_record(payload))
    identity = Devdash::Models::SourceIdentity.find_by!(source: "slack", external_id: "U001")
    identity.update!(resolution_method: "manual")

    expect { described_class.reset! }.not_to change(Devdash::Models::Person, :count)
    expect(person.reload).to be_persisted
    expect(identity.reload).to have_attributes(person_id: person.id, resolution_method: "manual")
  end

  it "preserves a cross-source person and both identities during reset" do
    payload = { "id" => "U001", "name" => "alex-owner", "profile" => { "display_name" => "Alex" } }
    person = described_class.call(source_record(payload))
    observed_at = Time.utc(2026, 9, 3, 12)
    github_identity = Devdash::Models::SourceIdentity.create!(
      person:, source: "github", external_id: "GH001", first_observed_at: observed_at, last_observed_at: observed_at
    )

    expect { described_class.reset! }.not_to change(Devdash::Models::Person, :count)
    expect(person.reload.source_identities).to contain_exactly(
      Devdash::Models::SourceIdentity.find_by!(source: "slack", external_id: "U001"), github_identity
    )
  end

  it "removes an unresolved Slack-only person and identity during reset" do
    payload = { "id" => "U001", "name" => "alex-owner", "profile" => { "display_name" => "Alex" } }
    person = described_class.call(source_record(payload))
    identity = Devdash::Models::SourceIdentity.find_by!(source: "slack", external_id: "U001")

    expect { described_class.reset! }.to change(Devdash::Models::Person, :count).by(-1)
    expect { person.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(Devdash::Models::SourceIdentity.exists?(identity.id)).to be(false)
  end
end
