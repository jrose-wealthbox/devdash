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
end
