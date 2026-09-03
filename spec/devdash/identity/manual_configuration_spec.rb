# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/identity/manual_configuration"

RSpec.describe Devdash::Identity::ManualConfiguration do
  let(:yaml) do
    <<~YAML
      owner: john
      people:
        john:
          identities:
            github: jrose-wealthbox
            slack: U001
            linear: 11111111-1111-1111-1111-111111111111
          role: software_engineer
          level: senior
        excluded-contractor:
          exclude_from_cohort: true
      role_rules:
        - id: senior-engineer
          pattern: '(?i)senior.*(software|full.stack|rails).*engineer'
          role: software_engineer
          level: senior
      repository_mappings:
        linear_projects:
          CRM: crm-web
        linear_labels:
          repo:repo1: repo1
    YAML
  end

  def load_config(contents = yaml, **options)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "people.yml")
      File.write(path, contents)
      return described_class.load(path:, repository_aliases: %w[crm-web repo1], **options)
    end
  end

  it "loads the documented shape and exposes immutable overrides" do
    config = load_config

    expect(config.owner).to eq("john")
    expect(config.people.fetch("john")).to have_attributes(role: "software_engineer", level: "senior")
    expect(config.people.fetch("excluded-contractor").exclude_from_cohort).to be(true)
    expect(config.role_rules.first.fetch(:pattern).match?("Senior Software Engineer")).to be(true)
    expect(config.role_rules.first.fetch(:id)).to eq("senior-engineer")
    expect(config.repository_mappings.fetch("linear_projects").fetch("CRM")).to eq("crm-web")
  end

  it "rejects unknown identity sources" do
    expect { load_config(yaml.sub("linear:", "jira:")) }
      .to raise_error(Devdash::ConfigurationError, /unknown source/i)
  end

  it "rejects duplicate external identities" do
    contents = <<~YAML
      owner: john
      people:
        john:
          identities:
            slack: U001
        other:
          identities:
            slack: U001
    YAML

    expect { load_config(contents) }
      .to raise_error(Devdash::ConfigurationError, /duplicate.*identity/i)
  end

  it "rejects unknown repository selectors" do
    expect { load_config(yaml.sub("repo1: repo1", "repo1: missing")) }
      .to raise_error(Devdash::ConfigurationError, /unknown repository/i)
  end

  it "rejects invalid regular expressions" do
    expect { load_config(yaml.sub("(?i)senior", "(")) }
      .to raise_error(Devdash::ConfigurationError, /regular expression|regex/i)
  end

  it "requires an owner that names a configured person" do
    expect { load_config(yaml.sub("owner: john", "owner: nobody")) }
      .to raise_error(Devdash::ConfigurationError, /owner/i)
  end

  it "rejects contradictory duplicate role rules" do
    contradictory = <<~YAML
      owner: john
      people:
        john: {}
      role_rules:
        - id: first
          pattern: 'senior engineer'
          role: software_engineer
          level: senior
        - id: second
          pattern: 'senior engineer'
          role: product
          level: lead
    YAML

    expect { load_config(contradictory) }
      .to raise_error(Devdash::ConfigurationError, /contradictory|overlap/i)
  end
end
