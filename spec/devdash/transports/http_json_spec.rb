# frozen_string_literal: true

require "devdash/transports/http_json"

RSpec.describe Devdash::Transports::HttpJson do
  let(:transport) { described_class.new(base_uri: "https://api.example.test", sleeper: ->(_seconds) {}) }

  it "parses a GET response and encodes the query" do
    stub_request(:get, "https://api.example.test/items?q=hello+world&page=2")
      .to_return(status: 200, body: '{"items":[{"id":1}]}', headers: { "Content-Type" => "application/json" })

    response = transport.get(path: "/items", query: { q: "hello world", page: 2 }, headers: {})

    expect(response.status).to eq(200)
    expect(response.body).to eq("items" => [{ "id" => 1 }])
  end

  it "classifies authentication failures without exposing headers" do
    stub_request(:get, "https://api.example.test/items").to_return(status: 401, body: "token=secret")

    error = nil
    expect { transport.get(path: "/items", query: {}, headers: { "Authorization" => "Bearer secret" }) }
      .to raise_error(Devdash::Transports::AuthenticationError) { |raised| error = raised }

    expect(error.message).not_to include("secret", "Bearer")
  end

  it "retries rate limits using Retry-After" do
    delays = []
    client = described_class.new(base_uri: "https://api.example.test", sleeper: ->(seconds) { delays << seconds })
    stub_request(:get, "https://api.example.test/items")
      .to_return({ status: 429, headers: { "Retry-After" => "2" } }, { status: 200, body: '{"ok":true}' })

    expect(client.get(path: "/items", query: {}, headers: {}).body).to eq("ok" => true)
    expect(delays).to eq([2.0])
  end

  it "retries transient gateway failures with exponential delay" do
    delays = []
    client = described_class.new(base_uri: "https://api.example.test", max_retries: 2, sleeper: ->(seconds) { delays << seconds })
    stub_request(:get, "https://api.example.test/items")
      .to_return({ status: 502 }, { status: 503 }, { status: 200, body: '{"ok":true}' })

    expect(client.get(path: "/items", query: {}, headers: {}).body).to eq("ok" => true)
    expect(delays).to eq([1.0, 2.0])
  end

  it "raises a response error for malformed JSON" do
    stub_request(:get, "https://api.example.test/items").to_return(status: 200, body: "not-json")

    expect {
      transport.get(path: "/items", query: {}, headers: {})
    }.to raise_error(Devdash::Transports::ResponseError, /invalid JSON/)
  end
end
