# frozen_string_literal: true

require_relative "../../../spec_helper"
require_relative "../../../../lib/devdash/models/linear_issue"
require_relative "../../../../lib/devdash/sources/linear/collector"

RSpec.describe Devdash::Sources::Linear::Collector do
  before { connect_test_database! }

  it "uses a global scope and forwards the incremental lower bound" do
    client = instance_double(Devdash::Sources::Linear::Client)
    writer = instance_double(Devdash::Ingestion::Writer, call: true)
    allow(client).to receive(:each_issue)
    allow(client).to receive(:issue_history).and_return([])
    collector = described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 3) })
    collector.call(since: Time.utc(2026, 1, 1))
    expect(client).to have_received(:each_issue).with(updated_since: Time.utc(2026, 1, 1))
    expect(writer).to have_received(:call).with(having_attributes(source: "linear", scope_key: "global"))
  end

  it "reports progress while fetching issues and history" do
    client = instance_double(Devdash::Sources::Linear::Client)
    writer = instance_double(Devdash::Ingestion::Writer, call: true)
    progress = []
    allow(client).to receive(:each_issue).and_yield({ "id" => "issue-1", "updatedAt" => "2026-01-02T00:00:00Z" })
    allow(client).to receive(:issue_history).with(id: "issue-1").and_return([])

    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 3) }, progress: ->(message) { progress << message })
      .call(since: Time.utc(2026, 1, 1))

    expect(progress).to include(
      "linear/global: fetching issues",
      "linear/global: fetched issue issue-1 (1)",
      "linear/global: fetching history for issue-1 (1/1)",
      "linear/global: finished (1 issues)"
    )
  end

  it "reports progress while refreshing active issues" do
    Devdash::Models::LinearIssue.create!(linear_id: "active-1", identifier: "ENG-1", title: "Active issue", active: true)
    client = instance_double(Devdash::Sources::Linear::Client)
    writer = instance_double(Devdash::Ingestion::Writer, call: true)
    progress = []
    allow(client).to receive(:each_issue)
    allow(client).to receive(:issue).with(id: "active-1").and_return({ "id" => "active-1", "updatedAt" => "2026-01-02T00:00:00Z" })
    allow(client).to receive(:issue_history).with(id: "active-1").and_return([])

    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 3) }, progress: ->(message) { progress << message })
      .call(since: Time.utc(2026, 1, 1))

    expect(progress).to include("linear/global: refreshing active issue active-1 (1/1)")
  end

  it "does not claim history coverage for an active issue that was not fetched" do
    Devdash::Models::LinearIssue.create!(linear_id: "issue-1", identifier: "ENG-1", title: "Old issue", active: true)
    client = instance_double(Devdash::Sources::Linear::Client)
    batch = nil
    writer = instance_double(Devdash::Ingestion::Writer)
    allow(writer).to receive(:call) { |value| batch = value }
    allow(client).to receive(:each_issue)
    allow(client).to receive(:issue).with(id: "issue-1").and_return(nil)
    collector = described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 3) })

    collector.call(since: Time.utc(2026, 1, 1))

    history_coverage = batch.coverages.find { |coverage| coverage[:entity_type] == "linear_issue_history" }
    expect(history_coverage[:status]).to eq("partial")
  end

  it "refreshes a locally active issue through the dedicated lookup even when archived" do
    Devdash::Models::LinearIssue.create!(linear_id: "issue-archived", identifier: "ENG-9", title: "Old issue", active: true)
    client = instance_double(Devdash::Sources::Linear::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    issue = {
      "id" => "issue-archived", "identifier" => "ENG-9", "title" => "Archived issue",
      "updatedAt" => "2026-01-02T00:00:00Z", "createdAt" => "2025-12-01T00:00:00Z",
      "state" => { "id" => "state-1", "name" => "Todo", "type" => "backlog" },
      "creator" => nil, "assignee" => nil, "labels" => { "nodes" => [] }, "attachments" => { "nodes" => [] }
    }
    allow(client).to receive(:each_issue)
    allow(client).to receive(:issue).with(id: "issue-archived").and_return(issue)
    allow(client).to receive(:issue_history).with(id: "issue-archived").and_return([])
    batch = nil
    allow(writer).to receive(:call) { |value| batch = value }

    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 3) }).call(since: Time.utc(2026, 1, 1))

    expect(client).to have_received(:issue).with(id: "issue-archived")
    expect(batch.coverages).to all(include(status: "complete"))
    expect(batch.observations.map(&:external_id)).to include("issue-archived")
  end

  it "does not advance the cursor when an active issue refresh is uncovered" do
    cursor_value = "2026-01-03T00:00:00Z"
    Devdash::Models::SyncCursor.create!(source: "linear", scope_key: "global", cursor_type: "updated_at", cursor_value: cursor_value)
    Devdash::Models::LinearIssue.create!(linear_id: "issue-old", identifier: "ENG-8", title: "Old issue", active: true)
    client = instance_double(Devdash::Sources::Linear::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    allow(client).to receive(:each_issue).and_yield({ "id" => "issue-new", "updatedAt" => "2026-01-04T00:00:00Z" })
    allow(client).to receive(:issue).with(id: "issue-old").and_return(nil)
    allow(client).to receive(:issue_history).with(id: "issue-new").and_return([])
    batch = nil
    allow(writer).to receive(:call) { |value| batch = value }

    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 4, 12) }).call(since: Time.utc(2026, 1, 1))

    expect(batch.cursor_after).to eq(cursor_value)
    expect(batch.coverages).to all(include(status: "partial", achieved_end_at: nil))
  end

  it "marks relation hydration failures partial and retains the prior cursor" do
    cursor_value = "2026-01-03T00:00:00Z"
    Devdash::Models::SyncCursor.create!(source: "linear", scope_key: "global", cursor_type: "updated_at", cursor_value: cursor_value)
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_listing_single.json"))),
      instance_double(Devdash::Transports::HttpJson::Response,
        body: { "data" => { "issue" => nil } })
    )
    client = Devdash::Sources::Linear::Client.new(http:, api_key: "secret")
    writer = instance_double(Devdash::Ingestion::Writer)
    batch = nil
    allow(writer).to receive(:call) { |value| batch = value }

    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 4) }).call(since: Time.utc(2026, 1, 1))

    expect(batch.cursor_after).to eq(cursor_value)
    expect(batch.coverages).to all(include(status: "partial", achieved_end_at: nil))
  end

  it "loads its Linear model dependency when the collector is required directly" do
    expect(Devdash::Models::LinearIssue).to be_a(Class)
  end

  it "does not regress a prior cursor when returned issue timestamps are older" do
    Devdash::Models::SyncCursor.create!(source: "linear", scope_key: "global", cursor_type: "updated_at",
      cursor_value: "2026-01-03T00:00:00Z")
    client = instance_double(Devdash::Sources::Linear::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    issue = { "id" => "issue-1", "updatedAt" => "2026-01-02T00:00:00Z" }
    allow(client).to receive(:each_issue).and_yield(issue)
    allow(client).to receive(:issue_history).with(id: "issue-1").and_return([])
    batch = nil
    allow(writer).to receive(:call) { |value| batch = value }

    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 2, 12) }).call(since: Time.utc(2026, 1, 1))

    expect(batch.cursor_after).to eq("2026-01-03T00:00:00Z")
  end

  it "uses the successful observation boundary when it is newer than source timestamps" do
    client = instance_double(Devdash::Sources::Linear::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    issue = { "id" => "issue-1", "updatedAt" => "2026-01-02T00:00:00Z" }
    allow(client).to receive(:each_issue).and_yield(issue)
    allow(client).to receive(:issue_history).with(id: "issue-1").and_return([])
    batch = nil
    allow(writer).to receive(:call) { |value| batch = value }

    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 3) }).call(since: Time.utc(2026, 1, 1))

    expect(batch.cursor_after).to eq("2026-01-03T00:00:00Z")
  end
end
