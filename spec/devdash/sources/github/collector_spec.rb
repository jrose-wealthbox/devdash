# frozen_string_literal: true
require "devdash/sources/github/collector"

RSpec.describe Devdash::Sources::Github::Collector do
  it "expands every configured repository independently" do
    client = instance_double(Devdash::Sources::Github::Client)
    writer = instance_double(Devdash::Ingestion::Writer)
    allow(client).to receive(:repository).and_return({ "default_branch" => "main" })
    allow(client).to receive(:updated_pull_numbers).and_return([])
    allow(client).to receive(:open_pull_numbers).and_return([])
    allow(client).to receive(:default_branch_commits).and_return([])
    expect(writer).to receive(:call).twice
    scope = Devdash::RepositoryScope.new(key: "all", repository_names: ["o/a", "o/b"], label: "all", configuration_hash: "x")
    described_class.new(client:, writer:, clock: -> { Time.utc(2026, 1, 2) }).call(repository_scope: scope, since: Time.utc(2026, 1, 1))
  end
end
