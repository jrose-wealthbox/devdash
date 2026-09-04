# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/commands/sync"

RSpec.describe Devdash::Commands::Sync do
  let(:configuration) do
    Devdash::Configuration.new(raw: {
      "database_path" => ":memory:", "github" => { "repositories" => [
        { "name" => "acme/crm-web", "alias" => "crm-web", "default" => true, "enabled" => true }
      ] }
    }, config_path: "config/devdash.yml")
  end
  let(:summary) do
    Devdash::SyncRunner::Summary.new(results: [], started_at: Time.utc(2026, 1, 1), finished_at: Time.utc(2026, 1, 1))
  end

  it "qualifies post-fetch errors with the requested connector" do
    runner = instance_double(Devdash::SyncRunner, call: summary)
    reprocessor = instance_double(Devdash::Reprocessing::Reprocessor, call: nil)
    output = StringIO.new
    error_output = StringIO.new
    command = described_class.new(configuration:, sync_runner: runner,
      database: instance_double("Database", connect!: nil, migrate!: nil),
      cache: instance_double("Cache", clear!: nil), out: output, err: error_output)
    allow(command).to receive(:prepare_database!)
    allow(command).to receive(:resolve_identity_and_links)
      .and_raise(Devdash::ConfigurationError, "unknown repository selector: repo1")
    allow(Devdash::Reprocessing::Reprocessor).to receive(:new).and_return(reprocessor)

    expect { command.call(source: "linear") }
      .to raise_error(Devdash::ConfigurationError, "linear: unknown repository selector: repo1")
  end
end
