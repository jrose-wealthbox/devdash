# frozen_string_literal: true

require "json"

module LinearMetricFixture
  def build_linear_metric_fixture
    connect_test_database!
    @report_at = Time.utc(2026, 9, 3)
    @window = Devdash::Metrics::Window.for("7d", end_at: @report_at)

    @crm = Devdash::Models::Repository.create!(full_name: "acme/crm-web", alias_name: "crm-web")
    @platform = Devdash::Models::Repository.create!(full_name: "acme/platform", alias_name: "platform")
    @owner = person("Owner", owner: true)
    @peer = person("Peer")
    linear_identity(@owner, "linear-owner")
    linear_identity(@peer, "linear-peer")

    @creator_differs = issue(
      "linear-1", "CRM-101", creator: @peer, assignee: @owner,
      created_at: "2026-08-27T01:00:00Z", started_at: "2026-08-28T01:00:00Z",
      links: [[@crm, "github_pr:101", true, "resolved"]],
      events: [
        assignment_event("linear-1-assignee", "2026-08-28T00:00:00Z", nil, @owner, "linear-owner"),
        state_event("linear-1-complete", "2026-08-29T01:00:00Z", "In Progress", "Done", "started", "completed")
      ], completed_at: "2026-08-29T01:00:00Z"
    )

    @reassigned = issue(
      "linear-2", "CRM-102", creator: @owner, assignee: @peer,
      created_at: "2026-08-20T00:00:00Z", started_at: "2026-08-25T00:00:00Z",
      links: [[@crm, "github_pr:102", true, "resolved"]],
      events: [
        assignment_event("linear-2-assignee-owner", "2026-08-25T00:00:00Z", nil, @owner, "linear-owner"),
        assignment_event("linear-2-assignee-peer", "2026-08-28T00:00:00Z", @owner, @peer, "linear-peer"),
        state_event("linear-2-complete", "2026-08-29T02:00:00Z", "In Progress", "Done", "started", "completed")
      ], completed_at: "2026-08-29T02:00:00Z"
    )

    @no_assignee = issue(
      "linear-3", "CRM-103", creator: @peer, assignee: nil,
      created_at: "2026-08-26T00:00:00Z", started_at: "2026-08-27T00:00:00Z",
      links: [[@crm, "linear_project:crm", true, "resolved"]],
      events: [
        state_event("linear-3-complete", "2026-08-28T00:00:00Z", "In Progress", "Done", "started", "completed")
      ], completed_at: "2026-08-28T00:00:00Z"
    )

    @reopened = issue(
      "linear-4", "CRM-104", creator: @owner, assignee: @owner,
      created_at: "2026-08-10T00:00:00Z", started_at: "2026-08-11T00:00:00Z",
      links: [[@crm, "linear_project:crm", true, "resolved"]],
      events: [
        assignment_event("linear-4-assignee", "2026-08-11T00:00:00Z", nil, @owner, "linear-owner"),
        state_event("linear-4-complete-1", "2026-08-28T00:00:00Z", "In Progress", "Done", "started", "completed"),
        state_event("linear-4-reopen", "2026-08-29T00:00:00Z", "Done", "Todo", "completed", "backlog"),
        state_event("linear-4-restart", "2026-08-30T00:00:00Z", "Todo", "In Progress", "backlog", "started"),
        state_event("linear-4-complete-2", "2026-08-31T00:00:00Z", "In Progress", "Done", "started", "completed")
      ], completed_at: "2026-08-31T00:00:00Z"
    )

    @canceled = issue(
      "linear-5", "CRM-105", creator: @owner, assignee: @owner,
      created_at: "2026-08-28T00:00:00Z", started_at: nil,
      links: [[@crm, "linear_project:crm", true, "resolved"]],
      events: [
        assignment_event("linear-5-assignee", "2026-08-28T00:30:00Z", nil, @owner, "linear-owner"),
        state_event("linear-5-canceled", "2026-08-28T02:00:00Z", "Todo", "Canceled", "backlog", "canceled")
      ], canceled_at: "2026-08-28T02:00:00Z"
    )

    @multi_repo = issue(
      "linear-6", "CRM-106", creator: @owner, assignee: @owner,
      created_at: "2026-08-29T00:00:00Z", links: [
        [@crm, "linear_project:crm", false, "multi-repo"],
        [@platform, "linear_project:platform", false, "multi-repo"]
      ]
    )

    @unmapped = issue(
      "linear-7", "CRM-107", creator: @owner, assignee: @owner,
      created_at: "2026-08-30T00:00:00Z", links: []
    )
  end

  def owner
    @owner
  end

  def peer
    @peer
  end

  def window
    @window
  end

  def all_scope
    Devdash::RepositoryScope.new(key: "all", repository_names: [@crm.full_name, @platform.full_name],
      label: "All", configuration_hash: "fixture-all")
  end

  def crm_scope
    Devdash::RepositoryScope.new(key: "crm-web", repository_names: [@crm.full_name],
      label: "crm-web", configuration_hash: "fixture-crm")
  end

  private

  def person(name, **attributes)
    Devdash::Models::Person.create!({ display_name: name, active: true, human: true, bot: false, guest: false }.merge(attributes))
  end

  def linear_identity(person, external_id)
    Devdash::Models::SourceIdentity.create!(person:, source: "linear", external_id:, resolution_method: "manual")
  end

  def issue(linear_id, identifier, creator:, assignee:, created_at:, started_at: nil, completed_at: nil,
            canceled_at: nil, links:, events: [])
    record = Devdash::Models::LinearIssue.create!(
      linear_id:, identifier:, title: identifier, creator_person: creator, assignee_person: assignee,
      created_at_source: Time.iso8601(created_at), started_at_source: started_at && Time.iso8601(started_at),
      completed_at_source: completed_at && Time.iso8601(completed_at), canceled_at_source: canceled_at && Time.iso8601(canceled_at),
      state_type: completed_at ? "completed" : (canceled_at ? "canceled" : "started"),
      state_name: completed_at ? "Done" : (canceled_at ? "Canceled" : "In Progress"), active: !completed_at && !canceled_at
    )
    links.each do |repository, reference, primary, resolution_status|
      Devdash::Models::IssueRepositoryLink.create!(linear_issue: record, repository:, evidence_kind: "linear_project",
        evidence_reference: reference, primary:, resolution_status:, confidence: primary ? 1.0 : 0.8)
    end
    events.each { |event| event[:linear_issue] = record; Devdash::Models::LinearIssueEvent.create!(event) }
    record
  end

  def assignment_event(id, occurred_at, from_person, to_person, to_external_id, from_external_id = nil)
    {
      stable_external_id: id, kind: "assignee", actor_person: nil,
      from_value: from_person&.display_name, to_value: to_person&.display_name,
      occurred_at: Time.iso8601(occurred_at), derivation: id.include?("observed") ? "observed_diff" : "source_event",
      metadata_json: JSON.generate({ "fromAssigneeId" => from_external_id, "toAssigneeId" => to_external_id })
    }
  end

  def state_event(id, occurred_at, from, to, from_type, to_type)
    {
      stable_external_id: id, kind: "state", actor_person: nil,
      from_value: from, to_value: to, occurred_at: Time.iso8601(occurred_at), derivation: "source_event",
      metadata_json: JSON.generate({ "fromState" => { "name" => from, "type" => from_type },
        "toState" => { "name" => to, "type" => to_type } })
    }
  end
end
