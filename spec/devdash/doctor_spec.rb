# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/devdash/doctor"

RSpec.describe Devdash::Doctor do
  let(:directory) { Dir.mktmpdir("devdash-doctor-") }
  let(:database_path) { File.join(directory, "devdash.sqlite3") }
  let(:configuration) do
    Devdash::Configuration.new(raw: {
      "database_path" => database_path,
      "github" => { "repositories" => [
        { "name" => "acme/crm-web", "alias" => "crm-web", "default" => true, "enabled" => true }
      ] }
    }, config_path: File.join(directory, "devdash.yml"))
  end

  after { FileUtils.remove_entry(directory) if File.directory?(directory) }

  it "returns safe local diagnostics in offline mode without calling probes" do
    github_probe = ->(*) { raise "must not be called" }
    linear_probe = ->(*) { raise "must not be called" }
    slack_probe = ->(*) { raise "must not be called" }

    result = described_class.new(configuration:, offline: true, github_probe:, linear_probe:, slack_probe:,
      linear_token: "configured", slack_token: "configured",
      executable_lookup: ->(name) { "/usr/bin/#{name}" }, clock: -> { Time.utc(2026, 9, 3) }).call

    expect(result).to respond_to(:checks, :healthy?)
    expect(result.checks.map(&:key)).to include("configuration", "tools", "github_access", "linear_access", "slack_access")
    expect(result.checks.select { |check| check.key.end_with?("_access") }.map(&:status)).to all(eq("skipped"))
    expect(result.to_h.to_s).not_to match(/secret|token|Bearer|@/i)
  end

  it "treats missing gh as an error but missing maintainer tools as warnings" do
    result = described_class.new(configuration:, offline: true, executable_lookup: ->(name) {
      name == "gh" ? nil : "/usr/bin/#{name}"
    }).call

    tools = result.checks.find { |check| check.key == "tools" }
    expect(tools.severity).to eq("error")
    expect(tools.message).to include("gh")

    warning_result = described_class.new(configuration:, offline: true, linear_token: "configured", slack_token: "configured",
      executable_lookup: ->(name) {
      %w[gh jq].include?(name) ? "/usr/bin/#{name}" : nil
    }).call
    warning_tools = warning_result.checks.find { |check| check.key == "tools" }
    expect(warning_tools.severity).to eq("warning")
    expect(warning_tools.message).to include("rg", "ast-grep")
  end

  it "redacts credentials and raw API diagnostics from probe failures" do
    result = described_class.new(configuration:, github_probe: ->(*) {
      raise "Authorization: Bearer super-secret-token"
    }, linear_probe: ->(*) { raise "token=linear-secret" }, slack_probe: ->(*) { raise "payload email@example.com" },
      executable_lookup: ->(*) { "/usr/bin/tool" }).call

    messages = result.checks.map(&:message).join(" ")
    expect(messages).not_to include("super-secret-token", "linear-secret", "email@example.com")
    expect(result.checks.find { |check| check.key == "github_access" }.severity).to eq("error")
    expect(result.healthy?).to be(false)
  end
end
