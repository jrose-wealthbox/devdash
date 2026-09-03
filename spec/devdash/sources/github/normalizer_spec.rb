# frozen_string_literal: true
require "devdash/sources/github/normalizer"

RSpec.describe Devdash::Sources::Github::Normalizer do
  it "classifies generated, vendor, and lock paths" do
    normalizer = described_class.new
    expect(normalizer.send(:exclusion, "app/generated/schema.rb")).to eq("generated")
    expect(normalizer.send(:exclusion, "vendor/bundle/a.rb")).to eq("vendor")
    expect(normalizer.send(:exclusion, "Gemfile.lock")).to eq("lockfile")
    expect(normalizer.send(:exclusion, "app/models/user.rb")).to be_nil
  end
end
