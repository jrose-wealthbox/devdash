# frozen_string_literal: true

require "json"
require_relative "../../../spec_helper"
require_relative "../../../../lib/devdash/sources/linear/client"

RSpec.describe Devdash::Sources::Linear::Client do
  it "paginates issues and sends variables to the GraphQL endpoint" do
    responses = [
      instance_double(Devdash::Transports::HttpJson::Response, body: JSON.parse(File.read("spec/fixtures/linear/issues_page_1.json"))),
      instance_double(Devdash::Transports::HttpJson::Response, body: JSON.parse(File.read("spec/fixtures/linear/issues_page_2.json")))
    ]
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(*responses)
    nodes = described_class.new(http:, api_key: "secret").each_issue(updated_since: Time.utc(2026, 1, 1)) { |n| ( @nodes ||= []) << n }
    expect(@nodes.map { |n| n["id"] }).to eq(%w[issue-1 issue-2])
    expect(http).to have_received(:post).twice
    expect(http).to have_received(:post).with(hash_including(path: "/graphql", body: hash_including("variables" => hash_including("after" => "cursor-1")))).once
  end

  it "raises for top-level GraphQL errors" do
    http = instance_double(Devdash::Transports::HttpJson)
    allow(http).to receive(:post).and_return(instance_double(Devdash::Transports::HttpJson::Response,
      body: { "errors" => [{ "message" => "forbidden", "code" => "AUTH" }] }))
    expect { described_class.new(http:, api_key: "secret").each_issue { |_| } }.to raise_error(Devdash::Error, /AUTH: forbidden/)
  end
end
