# frozen_string_literal: true

RSpec.describe "foundation models" do
  it "associates a person with an organization and source identities" do
    connect_test_database!
    organization = Devdash::Models::Organization.create!(name: "Wealthbox")
    person = Devdash::Models::Person.create!(organization:, display_name: "John", owner: true)
    identity = Devdash::Models::SourceIdentity.create!(
      person:, source: "slack", external_id: "U1", first_observed_at: Time.current,
      last_observed_at: Time.current
    )

    expect(person.organization).to eq(organization)
    expect(person.source_identities).to contain_exactly(identity)
  end

  it "retains merged people and their merge audit" do
    connect_test_database!
    source = Devdash::Models::Person.create!(display_name: "Old")
    destination = Devdash::Models::Person.create!(display_name: "Current")
    source.update!(merged_into: destination)
    audit = Devdash::Models::PersonMergeAudit.create!(
      source_person: source, destination_person: destination,
      reason: "same email", evidence_reference: "slack:U1", merged_at: Time.current
    )

    expect(source.reload.merged_into).to eq(destination)
    expect(destination.person_merge_audits).to contain_exactly(audit)
  end

  it "rejects source evidence updates except normalizer metadata" do
    connect_test_database!
    run = Devdash::Models::CollectorRun.create!(
      source: "github", scope_key: "crm-web", status: "succeeded", started_at: Time.current
    )
    record = Devdash::Models::SourceRecord.create!(
      collector_run: run, source: "github", scope_key: "crm-web", entity_type: "commit",
      external_id: "c1", observed_at: Time.current, query_fingerprint: "q1",
      payload_hash: "h1", payload_json: '{"id":"c1"}', normalizer_version: 1
    )

    expect { record.update!(payload_json: '{"id":"changed"}') }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { record.update!(normalizer_version: 2) }.not_to raise_error
  end
end
