# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../lib/devdash/metrics/github/merged_pull_requests"
require_relative "../../../../lib/devdash/metrics/github/pr_ship_time"
require_relative "../../../../lib/devdash/metrics/github/authored_commits"
require_relative "../../../../lib/devdash/metrics/github/lines_shipped"
require_relative "../../../../lib/devdash/metrics/github/direct_push_lines"

RSpec.describe "GitHub delivery metrics" do
  let(:at) { Time.utc(2026, 9, 3) }
  let(:window) { Devdash::Metrics::Window.for("7d", end_at: at) }
  let(:all_scope) do
    Devdash::RepositoryScope.new(key: "all", repository_names: ["acme/crm-web", "acme/docs"],
      label: "All", configuration_hash: "all")
  end
  let(:crm_scope) do
    Devdash::RepositoryScope.new(key: "crm-web", repository_names: ["acme/crm-web"],
      label: "crm-web", configuration_hash: "crm")
  end

  before do
    connect_test_database!
    @owner = Devdash::Models::Person.create!(display_name: "Owner")
    @peer = Devdash::Models::Person.create!(display_name: "Peer")
    @crm = Devdash::Models::Repository.create!(source: "github", full_name: "acme/crm-web", alias_name: "crm-web",
      default_branch: "main", default_report: true)
    @docs = Devdash::Models::Repository.create!(source: "github", full_name: "acme/docs", alias_name: "docs",
      default_branch: "trunk")

    @default_pr = Devdash::Models::PullRequest.create!(repository: @crm, number: 1, author: @owner, state: "merged",
      base_branch: "main", opened_at: Time.utc(2026, 8, 25), merged_at: Time.utc(2026, 8, 29))
    @default_pr.pull_request_files.create!(path: "app/models/customer.rb", additions: 10, deletions: 3)
    @default_pr.pull_request_files.create!(path: "generated/schema.rb", additions: 100, deletions: 50,
      exclusion_category: "generated")

    @docs_pr = Devdash::Models::PullRequest.create!(repository: @docs, number: 2, author: @owner, state: "merged",
      base_branch: "trunk", opened_at: Time.utc(2026, 8, 30), merged_at: Time.utc(2026, 9, 1))
    @docs_pr.pull_request_files.create!(path: "README.md", additions: 4, deletions: 2)

    # A stacked/intermediate merge does not target the repository default branch.
    Devdash::Models::PullRequest.create!(repository: @crm, number: 3, author: @owner, state: "merged",
      base_branch: "feature/customer", opened_at: Time.utc(2026, 8, 27), merged_at: Time.utc(2026, 8, 28))
    Devdash::Models::PullRequest.create!(repository: @crm, number: 4, author: @owner, state: "open",
      base_branch: "main", opened_at: Time.utc(2026, 8, 31))

    commit = Devdash::Models::Commit.create!(repository: @crm, sha: "direct", author: @owner, parent_count: 1,
      default_branch_reachable: true, committed_at: Time.utc(2026, 8, 28))
    commit.commit_files.create!(path: "app/javascript/app.js", additions: 7, deletions: 2)
    merge = Devdash::Models::Commit.create!(repository: @crm, sha: "merge", author: @owner, parent_count: 2,
      default_branch_reachable: true, committed_at: Time.utc(2026, 8, 28))
    merge.commit_files.create!(path: "app/ignored.rb", additions: 500, deletions: 500)
    old = Devdash::Models::Commit.create!(repository: @crm, sha: "old", author: @owner, parent_count: 1,
      default_branch_reachable: true, committed_at: Time.utc(2026, 8, 26))
    old.commit_files.create!(path: "app/old.rb", additions: 99, deletions: 99)
    linked = Devdash::Models::Commit.create!(repository: @crm, sha: "linked", author: @owner, parent_count: 1,
      default_branch_reachable: true, pull_request: @default_pr, committed_at: Time.utc(2026, 8, 28))
    linked.commit_files.create!(path: "app/linked.rb", additions: 99, deletions: 99)
  end

  it "counts only authored default-branch merges and aggregates all repositories" do
    result = Devdash::Metrics::Github::MergedPullRequests.call(person: @owner, window:, repository_scope: all_scope)

    expect(result.value).to eq(2)
    expect(result.sample_count).to eq(2)
    expect(result.breakdown.fetch(:repositories)).to eq("acme/crm-web" => 1, "acme/docs" => 1)
  end

  it "reports median ship time across qualifying pull requests, including pre-window openings" do
    result = Devdash::Metrics::Github::PrShipTime.call(person: @owner, window:, repository_scope: all_scope)

    # (Aug 25 -> Aug 29 = 96h; Aug 30 -> Sep 1 = 48h; median = (48 + 96) / 2 = 72h.
    expect(result.value).to eq(72.0)
    expect(result.sample_count).to eq(2)
    expect(result.breakdown.fetch(:samples)).to eq([48.0, 96.0])
  end

  it "counts distinct reachable non-merge authored commits by commit timestamp" do
    result = Devdash::Metrics::Github::AuthoredCommits.call(person: @owner, window:, repository_scope: all_scope)

    expect(result.value).to eq(2)
    expect(result.breakdown.fetch(:repositories)).to eq("acme/crm-web" => 2, "acme/docs" => 0)
  end

  it "excludes generated lines while retaining included and excluded line breakdowns" do
    result = Devdash::Metrics::Github::LinesShipped.call(person: @owner, window:, repository_scope: all_scope)

    # crm-web: 10 + 3 included and 100 + 50 generated; docs: 4 + 2 included.
    expect(result.value).to eq(19)
    expect(result.breakdown.slice(:included_additions, :included_deletions, :excluded_additions, :excluded_deletions))
      .to eq(included_additions: 14, included_deletions: 5, excluded_additions: 100, excluded_deletions: 50)
    expect(result.breakdown.fetch(:repositories)).to eq("acme/crm-web" => 13, "acme/docs" => 6)
  end

  it "keeps direct-push lines separate from pull-request shipped lines" do
    result = Devdash::Metrics::Github::DirectPushLines.call(person: @owner, window:, repository_scope: crm_scope)

    expect(result.value).to eq(9)
    expect(result.breakdown.fetch(:repository_details).fetch("acme/crm-web")).to include(
      value: 9, additions: 7, deletions: 2, commit_count: 1
    )
  end

  it "exposes versioned definitions" do
    expect([
      Devdash::Metrics::Github::MergedPullRequests,
      Devdash::Metrics::Github::PrShipTime,
      Devdash::Metrics::Github::AuthoredCommits,
      Devdash::Metrics::Github::LinesShipped,
      Devdash::Metrics::Github::DirectPushLines
    ].map { |query| query.definition.key }).to eq([
      "github.merged_pull_requests.v1", "github.pr_ship_time_hours.v1", "github.authored_commits.v1",
      "github.lines_shipped.v1", "github.direct_push_lines.v1"
    ])
  end
end
