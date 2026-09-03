# frozen_string_literal: true

require "devdash/transports/command"

RSpec.describe Devdash::Transports::Command do
  it "passes environment and argv separately to the runner" do
    runner = double("runner")
    status = instance_double(Process::Status, success?: true, exitstatus: 0)
    expect(runner).to receive(:call)
      .with({ "GH_HOST" => "github.com" }, "gh", "api", "repos/o/r", stdin_data: "")
      .and_return(["{}", "", status])

    result = described_class.new(runner: runner).capture("gh", "api", "repos/o/r", env: { "GH_HOST" => "github.com" })

    expect(result.stdout).to eq("{}")
    expect(result.stderr).to eq("")
    expect(result.exitstatus).to eq(0)
  end

  it "raises a sanitized error for a failed command" do
    runner = double("runner")
    status = instance_double(Process::Status, success?: false, exitstatus: 1)
    allow(runner).to receive(:call).and_return(["", "authorization: Bearer secret-value", status])

    error = nil
    expect { described_class.new(runner: runner).capture("gh", "api", "repos/o/r") }
      .to raise_error(Devdash::Transports::CommandError) { |raised| error = raised }

    expect(error.message).to include("gh", "exit status 1")
    expect(error.message).not_to include("secret-value", "Bearer")
  end
end
