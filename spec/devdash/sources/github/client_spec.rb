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

  it "uses the required argv for every child endpoint" do
    command = instance_double(Devdash::Transports::Command)
    client = described_class.new(command:)
    allow(command).to receive(:capture).and_return(double(stdout: "[]"))

    client.repository("o/r")
    client.pull("o/r", 42)
    client.reviews("o/r", 42)
    client.timeline("o/r", 42)
    client.pull_files("o/r", 42)
    client.default_branch_commits("o/r", branch: "main", since: Time.utc(2026, 1, 1))
    client.commit_detail("o/r", "abc123")

    expect(command).to have_received(:capture).with("gh", "api", "repos/o/r").once
    expect(command).to have_received(:capture).with("gh", "api", "repos/o/r/pulls/42").once
    expect(command).to have_received(:capture).with("gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/o/r/pulls/42/reviews", "-f", "per_page=100").once
    expect(command).to have_received(:capture).with("gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/o/r/issues/42/timeline", "-H", "Accept: application/vnd.github+json", "-f", "per_page=100").once
    expect(command).to have_received(:capture).with("gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/o/r/pulls/42/files", "-f", "per_page=100").once
    expect(command).to have_received(:capture).with("gh", "api", "-X", "GET", "--paginate", "--slurp", "repos/o/r/commits", "-f", "sha=main", "-f", "since=2026-01-01T00:00:00Z", "-f", "per_page=100").once
    expect(command).to have_received(:capture).with("gh", "api", "repos/o/r/commits/abc123").once
  end

  it "returns search results and reports paginated page count" do
    command = instance_double(Devdash::Transports::Command)
    expect(command).to receive(:capture).with("gh", "api", "-X", "GET", "--paginate", "--slurp", "search/issues", "-f", "q=repo:o/r is:pr updated:2026-01-01T00:00:00Z..2026-01-02T00:00:00Z", "-f", "per_page=100")
      .and_return(double(stdout: JSON.generate([{ "total_count" => 2, "items" => [{ "number" => 1 }] }, { "total_count" => 2, "items" => [{ "number" => 2 }] }])))

    client = described_class.new(command:)
    expect(client.updated_pull_numbers("o/r", from: Time.utc(2026, 1, 1), to: Time.utc(2026, 1, 2))).to eq([1, 2])
    expect(client.page_count).to eq(2)
  end

  it "bisects an overfull interval before returning search results" do
    command = instance_double(Devdash::Transports::Command)
    allow(command).to receive(:capture) do |*argv|
      query = argv.find { |argument| argument.start_with?("q=") }
      from, to = query.split("updated:", 2).last.split("..")
      if to.to_time - from.to_time > 86_400
        double(stdout: JSON.generate([{ "total_count" => 901, "items" => [] }]))
      else
        double(stdout: JSON.generate([{ "total_count" => 1, "items" => [{ "number" => from.to_time.day }] }]))
      end
    end

    numbers = described_class.new(command:).updated_pull_numbers("o/r", from: Time.utc(2026, 1, 1), to: Time.utc(2026, 1, 3))
    expect(numbers).to contain_exactly(1, 2)
  end
end
