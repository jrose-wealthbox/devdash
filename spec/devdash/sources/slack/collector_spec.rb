require "spec_helper"
require_relative "../../../../lib/devdash/sources/slack/collector"

RSpec.describe Devdash::Sources::Slack::Collector do
  before do
    connect_test_database!
    Devdash::Sources::Slack.register_normalizer!
  end

  let(:users) { JSON.parse(File.read("spec/fixtures/slack/users_page_1.json"))["members"] }
  let(:client) { instance_double(Devdash::Sources::Slack::Client, each_user: users.each) }

  it "loads its client dependency and restores normalizer registration idempotently" do
    expect(Devdash::Sources::Slack::Client).to be

    Devdash::Normalizers::Registry.clear!

    expect { Devdash::Sources::Slack.register_normalizer! }.not_to raise_error
    expect(Devdash::Normalizers::Registry.fetch(source: "slack", entity_type: "user"))
      .to equal(Devdash::Sources::Slack::UserNormalizer)
    expect { Devdash::Sources::Slack.register_normalizer! }.not_to raise_error
  end

  it "persists a complete workspace snapshot and coverage" do
    run = described_class.new(client: client, clock: -> { Time.utc(2026, 9, 3, 12) }).call

    expect(run.status).to eq("succeeded")
    expect(Devdash::Models::SourceRecord.where(source: "slack", scope_key: "workspace").count).to eq(4)
    expect(Devdash::Models::CollectorRunCoverage.last).to have_attributes(
      scope_type: "global", scope_key: "workspace", entity_type: "user", status: "complete"
    )
    expect(Devdash::Models::SyncCursor.find_by(source: "slack", scope_key: "workspace").cursor_value).to eq("2025-09-03T09:03:00Z")
  end

  it "does not create duplicate source records when the same snapshot is collected twice" do
    collector = described_class.new(client: client, clock: -> { Time.utc(2026, 9, 3, 12) })
    collector.call
    collector.call

    expect(Devdash::Models::SourceRecord.count).to eq(4)
    expect(Devdash::Models::RoleAssignment.count).to eq(4)
    expect(Devdash::Models::CollectorRun.where(status: "succeeded").count).to eq(2)
  end

  it "persists a sanitized failed run when Slack authentication fails" do
    Devdash::Models::SyncCursor.create!(source: "slack", scope_key: "workspace", cursor_type: "full_snapshot",
      cursor_value: "previous")
    authentication_error = Devdash::Transports::AuthenticationError.new(
      "Authorization: Bearer slack-secret"
    )
    failing_client = instance_double(Devdash::Sources::Slack::Client)
    allow(failing_client).to receive(:each_user).and_raise(authentication_error)

    expect {
      described_class.new(client: failing_client, clock: -> { Time.utc(2026, 9, 3, 12) }).call
    }.to raise_error(Devdash::Transports::AuthenticationError, authentication_error.message)

    failed_run = Devdash::Models::CollectorRun.order(:id).last
    expect(failed_run).to have_attributes(
      source: "slack", scope_key: "workspace", status: "failed", cursor_before: "previous"
    )
    expect(failed_run.error_class).to eq("Devdash::Transports::AuthenticationError")
    expect(failed_run.error_message).not_to include("slack-secret", "Bearer")
    expect(Devdash::Models::SourceRecord.count).to eq(0)
    expect(Devdash::Models::CollectorRun.where(status: "succeeded").count).to eq(0)
    expect(Devdash::Models::SyncCursor.find_by(source: "slack", scope_key: "workspace").cursor_value)
      .to eq("previous")
  end

  it "rejects a missing or non-integer user updated timestamp before complete coverage" do
    [users.first.except("updated"), users.first.merge("updated" => "not-a-timestamp")].each do |invalid_user|
      invalid_client = instance_double(Devdash::Sources::Slack::Client,
        each_user: [invalid_user].each)

      expect {
        described_class.new(client: invalid_client, clock: -> { Time.utc(2026, 9, 3, 12) }).call
      }.to raise_error(ArgumentError, /updated timestamp/)

      expect(Devdash::Models::SourceRecord.count).to eq(0)
      expect(Devdash::Models::CollectorRun.where(status: "succeeded").count).to eq(0)
      expect(Devdash::Models::CollectorRunCoverage.count).to eq(0)
      expect(Devdash::Models::SyncCursor.find_by(source: "slack", scope_key: "workspace")).to be_nil
    end
  end
end
