# frozen_string_literal: true

require "spec_helper"
require_relative "../../../../lib/devdash/metrics/registry"
require_relative "../../../../lib/devdash/metrics/github/unique_pull_requests_reviewed"
require_relative "../../../../lib/devdash/metrics/github/reviews_submitted"
require_relative "../../../../lib/devdash/metrics/github/review_breadth"
require_relative "../../../../lib/devdash/metrics/github/review_pickup_time"
require_relative "../../../../lib/devdash/metrics/github/register"

RSpec.describe "GitHub review metrics" do
  let(:at) { Time.utc(2026, 9, 3) }
  let(:window) { Devdash::Metrics::Window.for("7d", end_at: at) }
  let(:scope) do
    Devdash::RepositoryScope.new(key: "all", repository_names: ["acme/crm-web", "acme/docs"],
      label: "All", configuration_hash: "all")
  end

  before do
    connect_test_database!
    @owner = Devdash::Models::Person.create!(display_name: "Owner")
    @peer = Devdash::Models::Person.create!(display_name: "Peer")
    @bot = Devdash::Models::Person.create!(display_name: "ci-bot", human: false, bot: true)
    @crm = Devdash::Models::Repository.create!(source: "github", full_name: "acme/crm-web", alias_name: "crm-web",
      default_branch: "main")
    @docs = Devdash::Models::Repository.create!(source: "github", full_name: "acme/docs", alias_name: "docs",
      default_branch: "trunk")

    @peer_pr = Devdash::Models::PullRequest.create!(repository: @crm, number: 10, author: @peer, state: "open",
      base_branch: "main", opened_at: Time.utc(2026, 8, 20))
    @peer_docs_pr = Devdash::Models::PullRequest.create!(repository: @docs, number: 11, author: @peer, state: "open",
      base_branch: "trunk", opened_at: Time.utc(2026, 8, 20))
    @owner_pr = Devdash::Models::PullRequest.create!(repository: @crm, number: 12, author: @owner, state: "open",
      base_branch: "main", opened_at: Time.utc(2026, 8, 20))

    Devdash::Models::PullRequestEvent.create!(pull_request: @peer_pr, stable_external_id: "request-1",
      kind: "review_requested", subject: @owner, occurred_at: Time.utc(2026, 8, 27), derivation: "github_timeline")
    Devdash::Models::PullRequestEvent.create!(pull_request: @peer_docs_pr, stable_external_id: "other-request",
      kind: "review_requested", subject: @peer, occurred_at: Time.utc(2026, 8, 27), derivation: "github_timeline")

    # Two stable submissions on one PR count as two reviews but one reviewed PR.
    review(@peer_pr, "101", "COMMENTED", Time.utc(2026, 8, 28), @owner)
    review(@peer_pr, "102", "APPROVED", Time.utc(2026, 8, 29), @owner)
    review(@peer_docs_pr, "103", "CHANGES_REQUESTED", Time.utc(2026, 8, 30), @owner)
    review(@peer_pr, "104", "APPROVED", Time.utc(2026, 8, 30), @bot)
    review(@peer_pr, "105", "APPROVED", Time.utc(2026, 8, 30), nil)
    review(@owner_pr, "106", "APPROVED", Time.utc(2026, 8, 30), @owner)
    # Pending reviews and line comments are not submitted review records.
    review(@peer_pr, "107", "PENDING", nil, @owner)
  end

  def review(pull_request, id, state, submitted_at, reviewer)
    Devdash::Models::PullRequestReview.create!(pull_request:, github_review_id: id, reviewer:, state:, submitted_at:)
  end

  it "counts unique non-self pull requests reviewed and aggregates by full repository identity" do
    result = Devdash::Metrics::Github::UniquePullRequestsReviewed.call(person: @owner, window:, repository_scope: scope)

    expect(result.value).to eq(2)
    expect(result.breakdown.fetch(:repositories)).to eq("acme/crm-web" => 1, "acme/docs" => 1)
  end

  it "counts stable submitted reviews with state breakdowns" do
    result = Devdash::Metrics::Github::ReviewsSubmitted.call(person: @owner, window:, repository_scope: scope)

    expect(result.value).to eq(3)
    expect(result.sample_count).to eq(3)
    expect(result.breakdown.slice(:approved, :commented, :changes_requested)).to eq(
      approved: 1, commented: 1, changes_requested: 1
    )
    expect(result.breakdown.fetch(:repositories)).to eq("acme/crm-web" => 2, "acme/docs" => 1)
  end

  it "counts distinct authors helped and reports repositories reviewed" do
    result = Devdash::Metrics::Github::ReviewBreadth.call(person: @owner, window:, repository_scope: scope)

    expect(result.value).to eq(1)
    expect(result.sample_count).to eq(1)
    expect(result.breakdown.fetch(:distinct_authors)).to eq(1)
    expect(result.breakdown.fetch(:repositories)).to eq("acme/crm-web" => 1, "acme/docs" => 1)
  end

  it "measures pickup from reviewer request to first subsequent submission" do
    result = Devdash::Metrics::Github::ReviewPickupTime.call(person: @owner, window:, repository_scope: scope)

    # The first request on crm-web was Aug 27 and first submission was Aug 28: 24h.
    expect(result.value).to eq(24.0)
    expect(result.sample_count).to eq(1)
    expect(result.breakdown.fetch(:samples)).to eq([24.0])
    expect(result.breakdown.fetch(:without_request)).to eq(1)
    expect(result.breakdown.fetch(:unresolved_reviewers)).to eq(1)
    expect(result.breakdown.fetch(:bot_or_unresolved_reviewers)).to eq(1)
    expect(result.breakdown.fetch(:self_reviews)).to eq(1)
  end

  it "registers all nine definitions through the task-local registration entrypoint" do
    registry = Devdash::Metrics::Registry.new
    Devdash::Metrics::Github::Register.call(registry)

    expect(registry.entries.map(&:key)).to contain_exactly(
      "github.merged_pull_requests.v1", "github.pr_ship_time_hours.v1", "github.authored_commits.v1",
      "github.lines_shipped.v1", "github.direct_push_lines.v1", "github.unique_prs_reviewed.v1",
      "github.reviews_submitted.v1", "github.review_breadth.v1", "github.review_pickup_time_hours.v1"
    )
  end
end
