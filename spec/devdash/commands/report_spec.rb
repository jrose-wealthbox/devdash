# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/commands/report"

RSpec.describe Devdash::Commands::Report do
  let(:configuration) do
    Devdash::Configuration.new(raw: {
      "database_path" => ":memory:", "github" => { "repositories" => [
        { "name" => "acme/crm-web", "alias" => "crm-web", "default" => true, "enabled" => true },
        { "name" => "acme/other", "alias" => "other", "enabled" => true }
      ] }
    }, config_path: "config/devdash.yml")
  end

  it "accepts the default, alias, full-name, and all repository selectors" do
    database = instance_double("Database", connect!: nil, migrate!: nil)
    owner = double(id: 1)
    builder = instance_double("Builder")
    allow(builder).to receive(:call).and_return(double)
    renderer = instance_double("Renderer", render: "report\n")
    allow(Devdash::Models::Person).to receive(:find_by).and_return(owner)
    allow(Devdash::Identity::ManualConfiguration).to receive(:load).and_return(double)
    %w[crm-web acme/crm-web all].each do |selector|
      command = described_class.new(configuration:, database:, builder:, renderer:, identity: double)
      expect { command.call(window: "7d", repository_selector: selector) }.not_to raise_error
    end
  end

  it "rejects invalid windows before any source call" do
    expect do
      described_class.new(configuration:).call(window: "2d")
    end.to raise_error(Devdash::Commands::UsageError, /invalid window/)
  end
end
