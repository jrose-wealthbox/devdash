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

  it "rejects GraphQL mutation POSTs" do
    expect {
      transport.post(path: "/graphql", body: { query: "mutation CreateThing { createThing { id } }" })
    }.to raise_error(Devdash::Transports::ResponseError, /read-only/)
  end

  it "rejects an absolute path before making a request" do
    expect {
      transport.get(path: "https://evil.example.test/steal", query: {}, headers: {})
    }.to raise_error(Devdash::Transports::ResponseError, /relative path/)

    expect(WebMock).not_to have_requested(:get, "https://evil.example.test/steal")
  end

  it "rejects a network-path reference before making a request" do
    expect {
      transport.get(path: "//evil.example.test/steal", query: {}, headers: {})
    }.to raise_error(Devdash::Transports::ResponseError, /relative path/)

    expect(WebMock).not_to have_requested(:get, "https://evil.example.test/steal")
  end

  it "allows a normal relative GET path" do
    stub_request(:get, "https://api.example.test/items").to_return(status: 200, body: '{"ok":true}')

    expect(transport.get(path: "items", query: {}, headers: {}).body).to eq("ok" => true)
  end

  it "rejects POSTs outside the configured GraphQL endpoint before making a request" do
    expect {
      transport.post(path: "/items", body: { query: "query { items { id } }" })
    }.to raise_error(Devdash::Transports::ResponseError, /GraphQL endpoint/)

    expect(WebMock).not_to have_requested(:post, "https://api.example.test/items")
  end

  it "rejects nil, non-Hash, and missing-query POST bodies before making requests" do
    [nil, "query { items { id } }", {}, { variables: {} }, { query: :not_a_string }].each do |body|
      expect {
        transport.post(path: "/graphql", body: body)
      }.to raise_error(Devdash::Transports::ResponseError, /read-only GraphQL query/)
    end
  end

  it "accepts normal and shorthand read-only GraphQL queries" do
    stub_request(:post, "https://api.example.test/graphql")
      .with(body: { query: "query GetItems { items { id } }" }.to_json)
      .to_return(status: 200, body: '{"data":{}}')
    expect(transport.post(path: "/graphql", body: { query: "query GetItems { items { id } }" }).body).to eq("data" => {})

    stub_request(:post, "https://api.example.test/graphql")
      .with(body: { query: "{ items { id } }" }.to_json)
      .to_return(status: 200, body: '{"data":{}}')
    expect(transport.post(path: "/graphql", body: { query: "{ items { id } }" }).body).to eq("data" => {})
  end

  it "rejects mutation operations anywhere in a GraphQL document" do
    [
      "query Read { items { id } } mutation Write { createItem { id } }",
      "query Read { items { id } }\nmutation Write($id: ID!) { deleteItem(id: $id) { id } }"
    ].each do |query|
      expect {
        transport.post(path: "/graphql", body: { query: query })
      }.to raise_error(Devdash::Transports::ResponseError, /read-only/)
    end

    expect(WebMock).not_to have_requested(:post, "https://api.example.test/graphql")
  end

  it "clamps negative and huge numeric Retry-After values" do
    delays = []
    client = described_class.new(base_uri: "https://api.example.test", sleeper: ->(seconds) { delays << seconds })
    stub_request(:get, "https://api.example.test/negative")
      .to_return({ status: 429, headers: { "Retry-After" => "-10" } }, { status: 200, body: '{"ok":true}' })
    stub_request(:get, "https://api.example.test/huge")
      .to_return({ status: 429, headers: { "Retry-After" => "999999999" } }, { status: 200, body: '{"ok":true}' })

    client.get(path: "/negative", query: {}, headers: {})
    client.get(path: "/huge", query: {}, headers: {})

    expect(delays).to eq([0.0, 300.0])
  end
end
