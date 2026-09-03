# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/identity/manual_configuration"
require_relative "../../../lib/devdash/identity/issue_repository_resolver"

RSpec.describe Devdash::Identity::IssueRepositoryResolver do
  before { connect_test_database! }

  def configuration(yaml)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "people.yml")
      File.write(path, yaml)
      return Devdash::Identity::ManualConfiguration.load(path:, repository_aliases: %w[crm-web repo1])
    end
  end

  let!(:crm) { Devdash::Models::Repository.create!(full_name: "acme/crm-web", alias_name: "crm-web") }
  let!(:repo1) { Devdash::Models::Repository.create!(full_name: "acme/repo1", alias_name: "repo1") }

  it "prefers configured GitHub PR evidence and preserves multiple candidates" do
    config = configuration(<<~YAML)
      owner: john
      people:
        john: {}
      repository_mappings:
        linear_projects:
          CRM: crm-web
    YAML
    issue = Devdash::Models::LinearIssue.create!(linear_id: "l1", identifier: "CRM-1", title: "Fix")

    links = described_class.new(configuration: config).call(issue:, github_links: [
      { repository: crm, reference: "pr:1" }, { repository: repo1, reference: "pr:2" }
    ])

    expect(links.map(&:resolution_status).uniq).to eq(["multi-repo"])
    expect(links.map(&:primary).uniq).to eq([false])
    expect(issue.issue_repository_links.count).to eq(3)
  end

  it "uses one explicit primary override, then mappings, tokens, and unmapped" do
    config = configuration(<<~YAML)
      owner: john
      people:
        john: {}
      repository_mappings:
        linear_projects:
          CRM: crm-web
        primary_issues:
          CRM-2: repo1
        enable_identifier_tokens: true
    YAML
    mapped = Devdash::Models::LinearIssue.create!(linear_id: "l1", identifier: "CRM-1", title: "Fix")
    overridden = Devdash::Models::LinearIssue.create!(linear_id: "l2", identifier: "CRM-2", title: "Fix")
    token = Devdash::Models::LinearIssue.create!(linear_id: "l3", identifier: "OTHER-1", title: "[crm-web] Fix")
    unknown = Devdash::Models::LinearIssue.create!(linear_id: "l4", identifier: "OTHER-2", title: "Fix")
    resolver = described_class.new(configuration: config)

    expect(resolver.call(issue: mapped).first).to have_attributes(repository_id: crm.id, primary: true, resolution_status: "resolved")
    expect(resolver.call(issue: overridden).first).to have_attributes(repository_id: repo1.id, primary: true, resolution_status: "resolved")
    expect(resolver.call(issue: token).first).to have_attributes(repository_id: crm.id, primary: true)
    expect(resolver.call(issue: unknown).first).to have_attributes(repository_id: nil, primary: false, resolution_status: "unmapped")
  end
end
