# frozen_string_literal: true
require "json"
require "devdash/sources/github/client"

RSpec.describe Devdash::Sources::Github::Client do
  it "uses argv arrays and flattens slurped pages" do
    command = instance_double(Devdash::Transports::Command)
    expect(command).to receive(:capture).with("gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/o/r/pulls", "-f", "state=open", "-f", "per_page=100").and_return(double(stdout: JSON.generate([[{"number" => 4}], [{"number" => 5}]])))
    expect(described_class.new(command:).open_pull_numbers("o/r")).to eq([4, 5])
  end

  it "raises the typed command error unchanged" do
    command = instance_double(Devdash::Transports::Command)
    expect(command).to receive(:capture).and_raise(Devdash::Transports::CommandError, "gh failed [REDACTED]")
    expect { described_class.new(command:).pull("o/r", 1) }.to raise_error(Devdash::Transports::CommandError, /REDACTED/)
  end
end
