require "spec_helper"
require "json"
require_relative "../../../../lib/devdash/sources/slack/client"

RSpec.describe Devdash::Sources::Slack::Client do
  let(:transport) { instance_double(Devdash::Transports::HttpJson) }
  let(:client) { described_class.new(transport: transport, token: "slack-secret") }
  let(:page_one) { JSON.parse(File.read("spec/fixtures/slack/users_page_1.json")) }
  let(:page_two) { JSON.parse(File.read("spec/fixtures/slack/users_page_2.json")) }

  it "iterates paginated users with a bounded page size" do
    allow(transport).to receive(:get).with(path: "/api/users.list", query: { "limit" => "200" }, headers: { "Authorization" => "Bearer slack-secret" })
      .and_return(instance_double(Devdash::Transports::HttpJson::Response, body: page_one))
    allow(transport).to receive(:get).with(path: "/api/users.list", query: { "limit" => "200", "cursor" => "page-two" }, headers: { "Authorization" => "Bearer slack-secret" })
      .and_return(instance_double(Devdash::Transports::HttpJson::Response, body: page_two))

    expect(client.each_user.map { |user| user.fetch("id") }).to eq(%w[U001 U002 U003 U004 U005 U006])
    expect(client.page_count).to eq(2)
    expect(transport).to have_received(:get).twice
    expect(transport).not_to have_received(:get).with(hash_including(path: a_string_matching(/conversations|history/)))
  end

  it "resets the page count for each enumeration" do
    response = instance_double(Devdash::Transports::HttpJson::Response,
      body: { "ok" => true, "members" => [{ "id" => "U001" }] })
    allow(transport).to receive(:get).with(path: "/api/users.list", query: { "limit" => "200" }, headers: { "Authorization" => "Bearer slack-secret" })
      .and_return(response)

    2.times { client.each_user.to_a }

    expect(client.page_count).to eq(1)
  end

  it "strips nonblank cursors and stops on whitespace-only cursors" do
    first_page = { "ok" => true, "members" => [{ "id" => "U001" }],
      "response_metadata" => { "next_cursor" => "  page-two  " } }
    final_page = { "ok" => true, "members" => [{ "id" => "U002" }],
      "response_metadata" => { "next_cursor" => " \t" } }
    allow(transport).to receive(:get).with(path: "/api/users.list", query: { "limit" => "200" }, headers: { "Authorization" => "Bearer slack-secret" })
      .and_return(instance_double(Devdash::Transports::HttpJson::Response, body: first_page))
    allow(transport).to receive(:get).with(path: "/api/users.list", query: { "limit" => "200", "cursor" => "page-two" }, headers: { "Authorization" => "Bearer slack-secret" })
      .and_return(instance_double(Devdash::Transports::HttpJson::Response, body: final_page))

    expect(client.each_user.map { |user| user.fetch("id") }).to eq(%w[U001 U002])
    expect(transport).to have_received(:get).twice
  end

  it "raises an authentication error for Slack body-level invalid_auth" do
    allow(transport).to receive(:get).and_return(instance_double(Devdash::Transports::HttpJson::Response,
      body: { "ok" => false, "error" => "invalid_auth" }))

    expect { client.each_user.to_a }.to raise_error(Devdash::Transports::AuthenticationError)
  end

  it "rejects successful responses with missing or malformed members" do
    malformed_bodies = [
      { "ok" => true },
      { "ok" => true, "members" => {} },
      { "ok" => true, "members" => [nil] },
      { "ok" => true, "members" => [{ "id" => "" }] },
      { "ok" => true, "members" => [{ "id" => 123 }] }
    ]

    malformed_bodies.each do |body|
      allow(transport).to receive(:get).with(path: "/api/users.list", query: { "limit" => "200" }, headers: { "Authorization" => "Bearer slack-secret" })
        .and_return(instance_double(Devdash::Transports::HttpJson::Response, body: body))

      expect { client.each_user.to_a }
        .to raise_error(Devdash::Transports::ResponseError, /malformed members/)
    end
  end
end
