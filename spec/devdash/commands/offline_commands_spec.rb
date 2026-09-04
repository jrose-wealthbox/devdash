# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/commands/reprocess"
require_relative "../../../lib/devdash/commands/rebuild_derived"

RSpec.describe "offline commands" do
  let(:configuration) do
    Devdash::Configuration.new(raw: {
      "database_path" => ":memory:", "github" => { "repositories" => [
        { "name" => "acme/crm-web", "alias" => "crm-web", "default" => true, "enabled" => true }
      ] }
    }, config_path: "config/devdash.yml")
  end

  it "does not construct source transports for reprocess or rebuild-derived" do
    database = instance_double("Database", connect!: nil, migrate!: nil)
    reprocessor = instance_double("Reprocessor", call: [])
    cache = instance_double("Cache", clear!: 0)
    expect(Devdash::Sources::Github::Client).not_to receive(:new)
    expect(Devdash::Sources::Linear::Client).not_to receive(:new)
    expect(Devdash::Sources::Slack::Client).not_to receive(:new)
    expect(Devdash::Commands::Reprocess.new(configuration:, database:, reprocessor:, cache:).call).to eq(0)
    expect(Devdash::Commands::RebuildDerived.new(configuration:, database:, cache:).call).to eq(0)
  end
end
