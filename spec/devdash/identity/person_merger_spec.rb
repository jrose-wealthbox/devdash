# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/identity/person_merger"
require_relative "../../../lib/devdash/models/pull_request"
require_relative "../../../lib/devdash/models/pull_request_event"
require_relative "../../../lib/devdash/models/pull_request_review"
require_relative "../../../lib/devdash/models/commit"
require_relative "../../../lib/devdash/models/linear_issue"
require_relative "../../../lib/devdash/models/linear_issue_event"

RSpec.describe Devdash::Identity::PersonMerger do
  before { connect_test_database! }

  it "moves every canonical person foreign key in one transaction and retains audit evidence" do
    organization = Devdash::Models::Organization.create!(name: "Acme")
    source = Devdash::Models::Person.create!(organization:, display_name: "Old")
    destination = Devdash::Models::Person.create!(organization:, display_name: "Current", owner: true)
    identity = Devdash::Models::SourceIdentity.create!(person: source, source: "slack", external_id: "U1",
      first_observed_at: Time.current, last_observed_at: Time.current)
    role = Devdash::Models::RoleAssignment.create!(person: source, source: "slack", original_title: "Engineer",
      effective_from: Time.current, observed_at: Time.current)
    repository = Devdash::Models::Repository.create!(full_name: "acme/app", alias_name: "app")
    pull = Devdash::Models::PullRequest.create!(repository:, number: 1, state: "open", author: source)
    event = Devdash::Models::PullRequestEvent.create!(pull_request: pull, stable_external_id: "e1", kind: "closed", actor: source, subject: source)
    review = Devdash::Models::PullRequestReview.create!(pull_request: pull, github_review_id: "r1", reviewer: source)
    commit = Devdash::Models::Commit.create!(repository:, sha: "abc", author: source, committer: source)
    issue = Devdash::Models::LinearIssue.create!(linear_id: "l1", identifier: "APP-1", title: "One", creator_person: source, assignee_person: source)
    issue_event = Devdash::Models::LinearIssueEvent.create!(linear_issue: issue, stable_external_id: "le1", kind: "state",
      actor_person: source, occurred_at: Time.current, derivation: "source_event")

    result = described_class.new(source_person: source, destination_person: destination,
      reason: "manual override", evidence_reference: "config/people.yml:john").call

    expect(result).to eq(destination)
    expect(identity.reload.person_id).to eq(destination.id)
    expect(role.reload.person_id).to eq(destination.id)
    expect(pull.reload.author_id).to eq(destination.id)
    expect(event.reload.actor_id).to eq(destination.id)
    expect(event.reload.subject_id).to eq(destination.id)
    expect(review.reload.reviewer_id).to eq(destination.id)
    expect(commit.reload.author_id).to eq(destination.id)
    expect(commit.reload.committer_id).to eq(destination.id)
    expect(issue.reload.creator_person_id).to eq(destination.id)
    expect(issue.reload.assignee_person_id).to eq(destination.id)
    expect(issue_event.reload.actor_person_id).to eq(destination.id)
    expect(source.reload).to have_attributes(active: false, merged_into_id: destination.id)
    expect(Devdash::Models::PersonMergeAudit.find_by!(source_person_id: source.id)).to have_attributes(
      destination_person_id: destination.id, reason: "manual override",
      evidence_reference: "config/people.yml:john"
    )
  end

  it "is idempotent when the same merge evidence is applied again" do
    source = Devdash::Models::Person.create!(display_name: "Old")
    destination = Devdash::Models::Person.create!(display_name: "Current")
    merger = described_class.new(source_person: source, destination_person: destination,
      reason: "email", evidence_reference: "email:one@example.test")

    expect { merger.call }.to change(Devdash::Models::PersonMergeAudit, :count).by(1)
    expect { merger.call }.not_to change(Devdash::Models::PersonMergeAudit, :count)
  end
end
