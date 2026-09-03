# frozen_string_literal: true

require "json"
require_relative "../../../spec_helper"
require_relative "../../../../lib/devdash/models/linear_issue"
require_relative "../../../../lib/devdash/models/linear_issue_event"
require_relative "../../../../lib/devdash/models/issue_repository_link"
require_relative "../../../../lib/devdash/sources/linear/normalizer"

RSpec.describe Devdash::Sources::Linear::Normalizer do
  before { connect_test_database! }

  it "exposes version one and keeps source events actor-null when absent" do
    expect(described_class.new.version).to eq(1)
  end

  describe ".register_normalizer!" do
    around do |example|
      Devdash::Normalizers::Registry.clear!
      example.run
    ensure
      Devdash::Normalizers::Registry.clear!
    end

    it "allows repeated registration of the shared normalizer" do
      Devdash::Sources::Linear.register_normalizer!

      expect { Devdash::Sources::Linear.register_normalizer! }.not_to raise_error
    end

    it "does not suppress a duplicate registration for another normalizer" do
      other_normalizer = double(version: 1, call: nil)
      Devdash::Normalizers::Registry.register(source: "linear", entity_type: "linear_issue", normalizer: other_normalizer)

      expect { Devdash::Sources::Linear.register_normalizer! }
        .to raise_error(ArgumentError, /normalizer already registered for linear:linear_issue/)
    end
  end

  def source_record(entity_type:, external_id:, payload:, observed_at: Time.utc(2026, 1, 1), source_updated_at: nil)
    run = Devdash::Models::CollectorRun.create!(source: "linear", scope_key: "global", status: "succeeded", started_at: observed_at)
    json = Devdash::Ingestion::CanonicalJson.dump(payload)
    Devdash::Models::SourceRecord.create!(collector_run: run, source: "linear", scope_key: "global", entity_type:, external_id:,
      observed_at:, source_updated_at:, api_version: "test", query_fingerprint: entity_type, payload_hash: Devdash::Ingestion::CanonicalJson.sha256(payload), payload_json: json)
  end

  def issue_payload(id:, updated_at:, state: "Todo", state_type: "backlog", assignee: nil, active: nil, **extra)
    {
      "id" => id, "identifier" => "ENG-1", "title" => "Issue", "updatedAt" => updated_at,
      "createdAt" => "2026-01-01T00:00:00Z", "completedAt" => nil, "canceledAt" => nil,
      "state" => { "id" => state.downcase, "name" => state, "type" => state_type },
      "assignee" => assignee, "creator" => nil, "labels" => { "nodes" => [] }, "attachments" => { "nodes" => [] }
    }.merge(active.nil? ? {} : { "active" => active }).merge(extra)
  end

  it "derives active from terminal state semantics instead of trusting payload active" do
    record = source_record(entity_type: "linear_issue", external_id: "issue-1",
      payload: issue_payload(id: "issue-1", updated_at: "2026-01-02T00:00:00Z", state: "Done", state_type: "completed", active: true))

    described_class.new.call(record)

    expect(Devdash::Models::LinearIssue.find_by!(linear_id: "issue-1").active).to be(false)
  end

  it "marks archived and trashed issues inactive while retaining raw archive metadata" do
    payload = JSON.parse(File.read("spec/fixtures/linear/issue_archived.json")).fetch("data").fetch("issue")
    record = source_record(entity_type: "linear_issue", external_id: payload.fetch("id"), payload:)

    described_class.new.call(record)

    issue = Devdash::Models::LinearIssue.find_by!(linear_id: payload.fetch("id"))
    expect(issue.active).to be(false)
    expect(JSON.parse(issue.metadata_json)).to include(
      "archivedAt" => "2026-01-02T01:00:00Z", "trashed" => true
    )
  end

  it "indexes Linear source lifecycle timestamps" do
    indexed_columns = ActiveRecord::Base.connection.indexes(:linear_issues).flat_map(&:columns)

    expect(indexed_columns).to include("created_at_source", "started_at_source", "canceled_at_source")
  end

  it "derives changes from the source chronology when observations are replayed out of order" do
    older = source_record(entity_type: "linear_issue", external_id: "issue-1", observed_at: Time.utc(2026, 1, 3),
      source_updated_at: Time.utc(2026, 1, 2), payload: issue_payload(id: "issue-1", updated_at: "2026-01-02T00:00:00Z"))
    newer = source_record(entity_type: "linear_issue", external_id: "issue-1", observed_at: Time.utc(2026, 1, 2),
      source_updated_at: Time.utc(2026, 1, 3), payload: issue_payload(id: "issue-1", updated_at: "2026-01-03T00:00:00Z", state: "Done", state_type: "completed"))

    normalizer = described_class.new
    normalizer.call(newer)
    normalizer.call(older)

    event = Devdash::Models::LinearIssueEvent.find_by!(derivation: "observed_diff")
    expect(event.from_value).to eq("Todo")
    expect(event.to_value).to eq("Done")
    expect(Devdash::Models::LinearIssue.find_by!(linear_id: "issue-1").state_name).to eq("Done")
  end

  it "upserts a stable history event when a later observation supplies actor and fields" do
    issue = source_record(entity_type: "linear_issue", external_id: "issue-1",
      payload: issue_payload(id: "issue-1", updated_at: "2026-01-02T00:00:00Z"))
    first_history = source_record(entity_type: "linear_issue_history", external_id: "history-snapshot-1",
      payload: { "issue_id" => "issue-1", "history" => [{ "id" => "history-1", "createdAt" => "2026-01-02T01:00:00Z", "fromEstimate" => 1, "toEstimate" => 3, "actor" => nil }] })
    later_history = source_record(entity_type: "linear_issue_history", external_id: "history-snapshot-2",
      payload: { "issue_id" => "issue-1", "history" => [
        { "id" => "history-1", "createdAt" => "2026-01-02T01:00:00Z", "fromEstimate" => 1, "toEstimate" => 3, "actor" => { "id" => "user-1", "name" => "Ada", "email" => "ada@example.test" } },
        { "id" => "history-2", "createdAt" => "2026-01-02T02:00:00Z", "changes" => { "priority" => { "from" => 3, "to" => 2 } }, "actor" => nil }
      ] })
    normalizer = described_class.new
    normalizer.call(issue)
    normalizer.call(first_history)
    normalizer.call(later_history)

    event = Devdash::Models::LinearIssueEvent.find_by!(stable_external_id: "history-1")
    expect(event.actor_person).to have_attributes(display_name: "Ada")
    expect(event.kind).to eq("estimate")
    expect(event.from_value).to eq("1")
    expect(event.to_value).to eq("3")
    expect(JSON.parse(event.metadata_json).fetch("actor").fetch("id")).to eq("user-1")

    changes_event = Devdash::Models::LinearIssueEvent.find_by!(stable_external_id: "history-2")
    expect(changes_event.from_value).to eq("3")
    expect(changes_event.to_value).to eq("2")
  end

  it "deep-merges nested raw changes across repeated history observations" do
    issue = source_record(entity_type: "linear_issue", external_id: "issue-1",
      payload: issue_payload(id: "issue-1", updated_at: "2026-01-02T00:00:00Z"))
    first_history = source_record(entity_type: "linear_issue_history", external_id: "history-snapshot-1",
      payload: { "issue_id" => "issue-1", "history" => [{
        "id" => "history-1", "createdAt" => "2026-01-02T01:00:00Z",
        "changes" => { "priority" => { "from" => 3, "to" => 2 } }
      }] })
    later_history = source_record(entity_type: "linear_issue_history", external_id: "history-snapshot-2",
      payload: { "issue_id" => "issue-1", "history" => [{
        "id" => "history-1", "createdAt" => "2026-01-02T01:00:00Z",
        "changes" => { "estimate" => { "from" => 1, "to" => 2 } }
      }] })

    normalizer = described_class.new
    normalizer.call(issue)
    normalizer.call(first_history)
    normalizer.call(later_history)

    changes = JSON.parse(Devdash::Models::LinearIssueEvent.find_by!(stable_external_id: "history-1").metadata_json).fetch("changes")
    expect(changes).to include(
      "priority" => { "from" => 3, "to" => 2 },
      "estimate" => { "from" => 1, "to" => 2 }
    )
  end

  it "derives a stable kind from supported history fields without a type field" do
    issue = source_record(entity_type: "linear_issue", external_id: "issue-1",
      payload: issue_payload(id: "issue-1", updated_at: "2026-01-02T00:00:00Z"))
    history = source_record(entity_type: "linear_issue_history", external_id: "history-snapshot-1",
      payload: { "issue_id" => "issue-1", "history" => [{
        "id" => "history-1", "createdAt" => "2026-01-02T01:00:00Z",
        "fromState" => { "id" => "state-1", "name" => "Todo" },
        "toState" => { "id" => "state-2", "name" => "Done" }
      }] })

    normalizer = described_class.new
    normalizer.call(issue)
    normalizer.call(history)

    event = Devdash::Models::LinearIssueEvent.find_by!(stable_external_id: "history-1")
    expect(event.kind).to eq("state")
    expect(event.from_value).to eq("Todo")
    expect(event.to_value).to eq("Done")
  end

  it "updates source identity metadata without replacing manual resolution" do
    person = Devdash::Models::Person.create!(display_name: "Manual Ada")
    identity = Devdash::Models::SourceIdentity.create!(person:, source: "linear", external_id: "user-1", resolution_method: "manual")
    record = source_record(entity_type: "linear_issue", external_id: "issue-1",
      payload: issue_payload(id: "issue-1", updated_at: "2026-01-02T00:00:00Z", creator: { "id" => "user-1", "name" => "Ada Updated", "email" => "ADA@EXAMPLE.TEST" }))

    described_class.new.call(record)

    expect(identity.reload.person_id).to eq(person.id)
    expect(identity.reload).to have_attributes(observed_display_name: "Ada Updated", normalized_email: "ada@example.test", resolution_method: "manual")
  end

  it "resets only unreferenced provisional Linear people" do
    shared = Devdash::Models::Person.create!(display_name: "Shared")
    owner = Devdash::Models::Person.create!(display_name: "Owner", owner: true)
    manual = Devdash::Models::Person.create!(display_name: "Manual")
    provisional = Devdash::Models::Person.create!(display_name: "Provisional")
    Devdash::Models::SourceIdentity.create!(person: shared, source: "slack", external_id: "U1")
    Devdash::Models::SourceIdentity.create!(person: shared, source: "linear", external_id: "linear-shared", resolution_method: "provisional")
    Devdash::Models::SourceIdentity.create!(person: owner, source: "linear", external_id: "linear-owner", resolution_method: "provisional")
    Devdash::Models::SourceIdentity.create!(person: manual, source: "linear", external_id: "linear-manual", resolution_method: "manual")
    Devdash::Models::SourceIdentity.create!(person: provisional, source: "linear", external_id: "linear-provisional", resolution_method: "provisional")

    described_class.new.reset!

    expect(Devdash::Models::Person.where(id: [shared, owner, manual, provisional].map(&:id)).pluck(:id)).to contain_exactly(shared.id, owner.id, manual.id)
    expect(Devdash::Models::SourceIdentity.where(source: "linear").pluck(:external_id)).to contain_exactly("linear-manual")
    expect(Devdash::Models::SourceIdentity.find_by(source: "slack", external_id: "U1")).to be_present
  end
end
