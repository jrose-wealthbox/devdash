# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/identity/manual_configuration"
require_relative "../../../lib/devdash/identity/cohort_resolver"

RSpec.describe Devdash::Identity::CohortResolver do
  before { connect_test_database! }

  def configuration(yaml)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "people.yml")
      File.write(path, yaml)
      return Devdash::Identity::ManualConfiguration.load(path:, repository_aliases: %w[app other])
    end
  end

  it "returns matching active humans with recent activity and inspectable exclusions" do
    config = configuration(<<~YAML)
      owner: john
      people:
        john:
          role: software_engineer
          level: senior
        excluded:
          exclude_from_cohort: true
    YAML
    at = Time.utc(2026, 9, 3)
    repo = Devdash::Models::Repository.create!(full_name: "acme/app", alias_name: "app", enabled: true, default_report: true)
    other = Devdash::Models::Repository.create!(full_name: "acme/other", alias_name: "other", enabled: true)
    owner = create_person("John", owner: true)
    peer = create_person("Peer")
    excluded = create_person("Excluded")
    bot = create_person("Bot", human: false, bot: true)
    manager = create_person("Manager")
    unresolved = create_person("Unresolved")
    assign_role(owner, "software_engineer", "senior", at - 10)
    [peer, excluded, bot, unresolved].each { |person| assign_role(person, "software_engineer", "senior", at - 10) }
    assign_role(manager, "engineering_manager", "senior", at - 10)
    Devdash::Models::SourceIdentity.create!(person: unresolved, source: "slack", external_id: "u", resolution_method: "unresolved",
      first_observed_at: at - 20, last_observed_at: at)
    Devdash::Models::PullRequest.create!(repository: repo, number: 1, state: "merged", author: peer, opened_at: at - 30)
    Devdash::Models::PullRequest.create!(repository: other, number: 2, state: "merged", author: excluded, opened_at: at - 30)

    result = described_class.new(configuration: config).call(owner:, at:, repository_scope: Devdash::RepositoryScope.new(
      key: "app", repository_names: ["acme/app"], label: "app", configuration_hash: "hash"
    ))

    expect(result.included_ids).to eq([peer.id])
    expect(result.exclusions).to include(
      owner.id => "owner", excluded.id => "excluded_by_configuration", bot.id => "bot",
      manager.id => "role_mismatch", unresolved.id => "unresolved"
    )
  end

  def create_person(name, **attributes)
    Devdash::Models::Person.create!({ display_name: name, active: true, human: true, bot: false, guest: false }.merge(attributes))
  end

  def assign_role(person, role, level, effective_from)
    Devdash::Models::RoleAssignment.create!(person:, source: "manual", original_title: role,
      normalized_role: role, normalized_level: level, effective_from:, observed_at: effective_from)
  end
end
