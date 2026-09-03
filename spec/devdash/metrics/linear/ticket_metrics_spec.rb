# frozen_string_literal: true

require "spec_helper"
require_relative "fixture"
require_relative "../../../../lib/devdash/metrics/linear/tickets_created"
require_relative "../../../../lib/devdash/metrics/linear/completed_while_assigned"
require_relative "../../../../lib/devdash/metrics/linear/reopened_tickets"
require_relative "../../../../lib/devdash/metrics/linear/register"
require_relative "../../../../lib/devdash/metrics/registry"

RSpec.describe "Linear ticket attribution metrics" do
  include LinearMetricFixture

  before { build_linear_metric_fixture }

  it "registers six versioned definitions for the report builder" do
    registry = Devdash::Metrics::Registry.new
    Devdash::Metrics::Linear::Register.call(registry)

    expect(registry.entries.map(&:key)).to eq([
      "linear.tickets_created.v1", "linear.completed_while_assigned.v1",
      "linear.queue_time_hours.v1", "linear.active_cycle_time_hours.v1",
      "linear.end_to_end_time_hours.v1", "linear.reopened_tickets.v1"
    ])
    expect(registry.entries).to all(satisfy { |entry| entry.definition.version == 1 })
  end

  it "counts tickets created by the person and exposes primary, multi-repo, and unmapped buckets" do
    result = Devdash::Metrics::Linear::TicketsCreated.call(person: owner, window:, repository_scope: all_scope)

    expect(result.value).to eq(3)
    expect(result.sample_count).to eq(3)
    expect(result.breakdown).to include(
      repository_values: { "acme/crm-web" => 1 },
      multi_repo: 1,
      unmapped: 1
    )
  end

  it "uses only the selected repository's primary links in a single-repository scope" do
    result = Devdash::Metrics::Linear::TicketsCreated.call(person: owner, window:, repository_scope: crm_scope)

    expect(result.value).to eq(1)
    expect(result.breakdown[:repository_values]).to eq("acme/crm-web" => 1)
    expect(result.breakdown[:multi_repo]).to eq(0)
    expect(result.breakdown[:unmapped]).to eq(0)
  end

  it "counts completion periods while assigned, not the person who authored the ticket" do
    owner_result = Devdash::Metrics::Linear::CompletedWhileAssigned.call(person: owner, window:, repository_scope: all_scope)
    peer_result = Devdash::Metrics::Linear::CompletedWhileAssigned.call(person: peer, window:, repository_scope: all_scope)

    expect(owner_result.definition.name).to eq("Tickets completed while assigned")
    expect(owner_result.value).to eq(3)
    expect(owner_result.breakdown).to include(distinct_issues: 2, recompleted_periods: 1)
    expect(peer_result.value).to eq(1)
  end

  it "does not use a current assignee snapshot to rewrite an earlier assignment" do
    owner_result = Devdash::Metrics::Linear::CompletedWhileAssigned.call(person: owner, window:, repository_scope: all_scope)
    peer_result = Devdash::Metrics::Linear::CompletedWhileAssigned.call(person: peer, window:, repository_scope: all_scope)

    # CRM-102 was assigned to Owner, reassigned to Peer, and then completed.
    expect(owner_result.breakdown[:issue_ids]).not_to include("linear-2")
    expect(peer_result.breakdown[:issue_ids]).to include("linear-2")
  end

  it "counts only completed-state reopens as a diagnostic" do
    result = Devdash::Metrics::Linear::ReopenedTickets.call(person: owner, window:, repository_scope: all_scope)

    expect(result.value).to eq(1)
    expect(result.definition.signal_role).to eq("diagnostic")
    expect(result.breakdown).to include(distinct_issues: 1, issue_ids: ["linear-4"])
  end

  it "uses stable event IDs as the deterministic tie breaker" do
    issue = Devdash::Models::LinearIssue.create!(linear_id: "linear-tie", identifier: "CRM-108", title: "Tie",
      creator_person: owner, assignee_person: owner, created_at_source: Time.utc(2026, 8, 28),
      completed_at_source: Time.utc(2026, 8, 29), state_type: "completed", state_name: "Done")
    Devdash::Models::IssueRepositoryLink.create!(linear_issue: issue, repository: @crm, evidence_kind: "manual_primary",
      evidence_reference: "CRM-108", primary: true, resolution_status: "resolved")
    Devdash::Models::LinearIssueEvent.create!(linear_issue: issue, stable_external_id: "z-assignment", kind: "assignee",
      to_value: owner.display_name, occurred_at: Time.utc(2026, 8, 29), derivation: "source_event",
      metadata_json: JSON.generate("toAssigneeId" => "linear-owner"))
    Devdash::Models::LinearIssueEvent.create!(linear_issue: issue, stable_external_id: "a-completion", kind: "state",
      from_value: "Todo", to_value: "Done", occurred_at: Time.utc(2026, 8, 29), derivation: "source_event",
      metadata_json: JSON.generate("fromState" => { "type" => "backlog" }, "toState" => { "type" => "completed" }))

    result = Devdash::Metrics::Linear::CompletedWhileAssigned.call(person: owner, window:, repository_scope: all_scope)

    expect(result.breakdown[:issue_ids]).not_to include("linear-tie")
  end
end
