# frozen_string_literal: true

require "json"
require_relative "../../../spec_helper"
require_relative "../../../../lib/devdash/models/linear_issue"
require_relative "../../../../lib/devdash/models/linear_issue_event"
require_relative "../../../../lib/devdash/models/issue_repository_link"
require_relative "../../../../lib/devdash/sources/linear/normalizer"

RSpec.describe Devdash::Sources::Linear::Normalizer do
  it "exposes version one and keeps source events actor-null when absent" do
    expect(described_class.new.version).to eq(1)
  end
end
