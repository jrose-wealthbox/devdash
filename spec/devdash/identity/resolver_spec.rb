# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/devdash/identity/manual_configuration"
require_relative "../../../lib/devdash/identity/person_merger"
require_relative "../../../lib/devdash/identity/resolver"

RSpec.describe Devdash::Identity::Resolver do
  before { connect_test_database! }

  def configuration(yaml)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "people.yml")
      File.write(path, yaml)
      return Devdash::Identity::ManualConfiguration.load(path:, repository_aliases: ["app"])
    end
  end

  it "uses manual identity mappings before exact normalized email and leaves display-name matches unresolved" do
    config = configuration(<<~YAML)
      owner: john
      people:
        john:
          identities:
            slack: U001
    YAML
    john = Devdash::Models::Person.create!(display_name: "John", owner: true)
    manual_source = Devdash::Models::Person.create!(display_name: "Slack John")
    email_source = Devdash::Models::Person.create!(display_name: "GitHub John")
    same_name = Devdash::Models::Person.create!(display_name: "John")
    now = Time.utc(2026, 9, 3)
    Devdash::Models::SourceIdentity.create!(person: manual_source, source: "slack", external_id: "U001",
      normalized_email: "john@example.test", first_observed_at: now, last_observed_at: now)
    Devdash::Models::SourceIdentity.create!(person: email_source, source: "github", external_id: "john",
      normalized_email: "john@example.test", first_observed_at: now, last_observed_at: now)
    Devdash::Models::SourceIdentity.create!(person: same_name, source: "linear", external_id: "lin-1",
      observed_display_name: "John", first_observed_at: now, last_observed_at: now)

    result = described_class.new(configuration: config).call

    expect(result.merged_count).to eq(2)
    expect(result.unresolved_count).to eq(1)
    expect(result.ambiguous_count).to eq(0)
    expect(manual_source.reload.merged_into_id).to eq(john.id)
    expect(email_source.reload.merged_into_id).to eq(john.id)
    expect(same_name.reload.merged_into_id).to be_nil
    expect(Devdash::Models::SourceIdentity.find_by!(source: "linear", external_id: "lin-1").resolution_method).to eq("unresolved")
  end

  it "reports an email collision between two explicitly mapped people without merging either" do
    config = configuration(<<~YAML)
      owner: john
      people:
        john:
          identities:
            slack: U001
        jane:
          identities:
            github: jane
    YAML
    john = Devdash::Models::Person.create!(display_name: "John", owner: true)
    jane = Devdash::Models::Person.create!(display_name: "Jane")
    slack = Devdash::Models::Person.create!(display_name: "Slack")
    github = Devdash::Models::Person.create!(display_name: "GitHub")
    now = Time.current
    Devdash::Models::SourceIdentity.create!(person: slack, source: "slack", external_id: "U001", normalized_email: "same@example.test",
      first_observed_at: now, last_observed_at: now)
    Devdash::Models::SourceIdentity.create!(person: github, source: "github", external_id: "jane", normalized_email: "same@example.test",
      first_observed_at: now, last_observed_at: now)

    result = described_class.new(configuration: config).call

    expect(result.ambiguous_count).to eq(1)
    expect(slack.reload.merged_into_id).to be_nil
    expect(github.reload.merged_into_id).to be_nil
    expect(john.reload.merged_into_id).to be_nil
    expect(jane.reload.merged_into_id).to be_nil
  end
end
