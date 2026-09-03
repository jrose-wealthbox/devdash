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
end
