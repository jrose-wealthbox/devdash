# frozen_string_literal: true

require "json"
require_relative "../../../spec_helper"
require_relative "../../../../lib/devdash/sources/linear/client"

RSpec.describe Devdash::Sources::Linear::Client do
  it "hydrates labels and attachments through bounded paginated queries" do
    responses = [
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_listing_single.json"))),
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_relations_page_1.json"))),
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_relations_page_2.json")))
    ]
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(*responses)

    nodes = []
    described_class.new(http:, api_key: "secret").each_issue { |node| nodes << node }

    expect(nodes.fetch(0).fetch("labels").fetch("nodes").map { |label| label.fetch("id") }).to eq(%w[label-1 label-2])
    expect(nodes.fetch(0).fetch("attachments").fetch("nodes").map { |attachment| attachment.fetch("id") }).to eq(%w[attachment-1 attachment-2])
    expect(http).to have_received(:post).exactly(3).times
    expect(http).to have_received(:post).with(hash_including(
      body: hash_including("query" => match(/issues\(filter: \$filter, first: 50, after: \$after, orderBy: updatedAt\)/))
    )) do |request|
      query = request.fetch(:body).fetch("query")
      expect(query).not_to match(/\b(labels|attachments)\b/)
    end
    expect(http).to have_received(:post).with(hash_including(
      body: hash_including(
        "query" => match(/labels\(first: 50, after: \$labelsAfter, includeArchived: true\)/),
        "variables" => hash_including("labelsAfter" => "labels-cursor-1", "attachmentsAfter" => "attachments-cursor-1")
      )
    )).once
  end

  it "paginates issues and sends variables to the GraphQL endpoint" do
    responses = [
      instance_double(Devdash::Transports::HttpJson::Response, body: JSON.parse(File.read("spec/fixtures/linear/issues_page_1.json"))),
      instance_double(Devdash::Transports::HttpJson::Response, body: JSON.parse(File.read("spec/fixtures/linear/issue_relations_page_2.json"))),
      instance_double(Devdash::Transports::HttpJson::Response, body: JSON.parse(File.read("spec/fixtures/linear/issues_page_2.json"))),
      instance_double(Devdash::Transports::HttpJson::Response, body: JSON.parse(File.read("spec/fixtures/linear/issue_relations_page_2.json")))
    ]
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(*responses)
    nodes = described_class.new(http:, api_key: "secret").each_issue(updated_since: Time.utc(2026, 1, 1)) { |n| ( @nodes ||= []) << n }
    expect(@nodes.map { |n| n["id"] }).to eq(%w[issue-1 issue-2])
    expect(http).to have_received(:post).exactly(4).times
    expect(http).to have_received(:post).with(hash_including(path: "/graphql", body: hash_including("variables" => hash_including("after" => "cursor-1")))).once
  end

  it "raises for top-level GraphQL errors" do
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(instance_double(Devdash::Transports::HttpJson::Response,
      body: { "errors" => [{ "message" => "forbidden", "code" => "AUTH" }] }))
    expect { described_class.new(http:, api_key: "secret").each_issue { |_| } }.to raise_error(Devdash::Error, /AUTH: forbidden/)
  end

  it "extracts GraphQL error codes from extensions" do
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(instance_double(Devdash::Transports::HttpJson::Response,
      body: { "errors" => [{ "message" => "forbidden", "extensions" => { "code" => "AUTH_EXT" } }] }))

    expect { described_class.new(http:, api_key: "secret").each_issue { |_| } }
      .to raise_error(Devdash::Error, /AUTH_EXT: forbidden/)
  end

  it "requires pageInfo on paginated connections" do
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(instance_double(Devdash::Transports::HttpJson::Response,
      body: { "data" => { "issues" => { "nodes" => [] } } }))

    expect { described_class.new(http:, api_key: "secret").each_issue { |_| } }
      .to raise_error(Devdash::Error, /missing pageInfo/)
  end

  it "uses a dedicated issue lookup so archived issues are refreshable" do
    responses = [
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_archived.json"))),
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_relations_empty.json")))
    ]
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(*responses)

    issue = described_class.new(http:, api_key: "secret").issue(id: "issue-archived")

    expect(issue.fetch("id")).to eq("issue-archived")
    expect(issue.fetch("archivedAt")).to eq("2026-01-02T01:00:00Z")
    expect(issue.fetch("trashed")).to be(true)
    expect(http).to have_received(:post).with(hash_including(
      body: hash_including("query" => match(/issue\(id: \$id\)/), "variables" => { "id" => "issue-archived" })
    )).once
    expect(http).to have_received(:post).with(hash_including(
      body: hash_including("query" => match(/labels\(first: 50, after: \$labelsAfter, includeArchived: true\)/))
    )).once
  end

  it "does not request Linear's unsupported active field" do
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(instance_double(Devdash::Transports::HttpJson::Response,
      body: { "data" => { "issues" => { "nodes" => [], "pageInfo" => { "hasNextPage" => false } } } }))

    described_class.new(http:, api_key: "secret").each_issue { |_| }

    expect(http).to have_received(:post) do |request|
      expect(request.fetch(:body).fetch("query")).not_to match(/\bactive\b/)
      expect(request.fetch(:body).fetch("query")).to include("archivedAt", "trashed")
    end
  end

  it "includes archived relation and history nodes" do
    expect(described_class::ISSUE_RELATIONS_QUERY).to include(
      "labels(first: 50, after: $labelsAfter, includeArchived: true)",
      "attachments(first: 50, after: $attachmentsAfter, includeArchived: true)"
    )
    expect(described_class::HISTORY_QUERY).to include("history(first: 100, after: $after, includeArchived: true)")
  end

  it "raises a typed error when relation hydration loses the issue object" do
    responses = [
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_listing_single.json"))),
      instance_double(Devdash::Transports::HttpJson::Response,
        body: { "data" => { "issue" => nil } })
    ]
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(*responses)

    expect { described_class.new(http:, api_key: "secret").each_issue { |_| } }
      .to raise_error(Devdash::Error, /missing data\.issue.*relation/i)
  end

  it "requests material history changes and their raw JSON metadata" do
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(instance_double(Devdash::Transports::HttpJson::Response,
      body: { "data" => { "issues" => { "nodes" => [], "pageInfo" => { "hasNextPage" => false } } } }))

    described_class.new(http:, api_key: "secret").each_issue { |_| }

    query = nil
    expect(http).to have_received(:post) do |request|
      query = request.fetch(:body).fetch("query")
    end
    expect(query).not_to include("history")
    expect(described_class::HISTORY_NODE_FIELDS).to include("changes", "removedLabelIds", "removedLabels", "attachmentId", "fromProjectMilestone")
  end

  it "keeps issue listing queries flat and excludes synthetic history fields" do
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(instance_double(Devdash::Transports::HttpJson::Response,
      body: { "data" => { "issues" => { "nodes" => [], "pageInfo" => { "hasNextPage" => false } } } }))

    described_class.new(http:, api_key: "secret").each_issue { |_| }

    expect(described_class::HISTORY_NODE_FIELDS).not_to match(/\btype\b/)
    expect(http).to have_received(:post) do |request|
      query = request.fetch(:body).fetch("query")
      expect(query).not_to include("history")
    end
  end

  it "paginates issue history independently using schema-shaped nodes" do
    responses = [
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_history_page_1.json"))),
      instance_double(Devdash::Transports::HttpJson::Response,
        body: JSON.parse(File.read("spec/fixtures/linear/issue_history_page_2.json")))
    ]
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(*responses)

    history = described_class.new(http:, api_key: "secret").issue_history(id: "issue-1")

    expect(history.map { |event| event.fetch("id") }).to eq(%w[history-1 history-2])
    expect(http).to have_received(:post).with(hash_including(
      body: hash_including("variables" => hash_including("id" => "issue-1", "after" => "history-cursor-1"))
    )).once
  end
end
