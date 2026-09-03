# frozen_string_literal: true
require "devdash/sources/github/normalizer"
require "securerandom"

RSpec.describe Devdash::Sources::Github::Normalizer do
  before { connect_test_database! }

  it "classifies generated, vendor, and lock paths" do
    normalizer = described_class.new
    expect(normalizer.send(:exclusion, "app/generated/schema.rb")).to eq("generated")
    expect(normalizer.send(:exclusion, "vendor/bundle/a.rb")).to eq("vendor")
    expect(normalizer.send(:exclusion, "Gemfile.lock")).to eq("lockfile")
    expect(normalizer.send(:exclusion, "app/models/user.rb")).to be_nil
  end

  it "honors configured globs with deterministic categories" do
    normalizer = described_class.new(exclusion_globs: ["docs/generated/**", "config/secrets/**"])
    expect(normalizer.send(:exclusion, "docs/generated/api.rb")).to eq("generated")
    expect(normalizer.send(:exclusion, "config/secrets/local.yml")).to eq("configured")
    expect(normalizer.send(:exclusion, "docs/generated-api.rb")).to be_nil
  end

  it "replaces a final pull file snapshot even when it is empty" do
    normalizer = described_class.new
    repository_record = source_record("repository", "github:o/r:repository", { "full_name" => "o/r", "node_id" => "repo-1" })
    pull_payload = { "number" => 42, "node_id" => "pr-42", "state" => "open", "user" => { "login" => "dev" } }
    pull_record = source_record("pull_request", "github:o/r:pull:42", pull_payload)
    files_record = source_record("pull_request_files", "github:o/r:pull_files:42", [{ "_pull_number" => 42, "filename" => "app.rb", "additions" => 1, "deletions" => 0 }])
    empty_record = source_record("pull_request_files", "github:o/r:pull_files:42", [])

    normalizer.call(repository_record)
    normalizer.call(pull_record)
    normalizer.call(files_record)
    expect { normalizer.call(empty_record) }.to change(Devdash::Models::PullRequestFile, :count).from(1).to(0)
  end

  it "deduplicates reviews and records requested reviewers as event subjects" do
    normalizer = described_class.new
    normalizer.call(source_record("repository", "github:o/r:repository", { "full_name" => "o/r" }))
    normalizer.call(source_record("pull_request", "github:o/r:pull:42", { "number" => 42, "state" => "open" }))
    review = { "_pull_number" => 42, "id" => 9, "state" => "approved", "user" => { "login" => "reviewer" } }
    normalizer.call(source_record("pull_request_reviews", "github:o/r:pull_reviews:42", [review, review]))
    event = { "_pull_number" => 42, "id" => 10, "event" => "review_requested", "actor" => { "login" => "requester" }, "requested_reviewer" => { "login" => "reviewer" } }
    normalizer.call(source_record("pull_request_timeline", "github:o/r:pull_event:42", [event]))

    expect(Devdash::Models::PullRequestReview.count).to eq(1)
    expect(Devdash::Models::PullRequestEvent.last).to have_attributes(kind: "review_requested", subject_login: "reviewer", actor_login: "requester")
    expect(Devdash::Models::SourceIdentity.find_by(source: "github", external_id: "reviewer"))
      .to have_attributes(resolution_method: "provisional")
  end

  it "keeps identical SHAs repository-qualified and records commit children" do
    normalizer = described_class.new
    detail = {
      "sha" => "same-sha", "author" => { "login" => "dev" }, "committer" => { "login" => "dev" },
      "commit" => {
        "author" => { "email" => "dev@example.test", "date" => "2026-01-01T00:00:00Z" },
        "committer" => { "email" => "dev@example.test", "date" => "2026-01-01T01:00:00Z" }
      },
      "parents" => [{ "sha" => "one" }, { "sha" => "two" }], "default_branch_reachable" => true,
      "files" => [{ "filename" => "app.rb", "status" => "modified", "additions" => 2, "deletions" => 1 }]
    }

    %w[o/a o/b].each do |name|
      normalizer.call(source_record("repository", "github:#{name}:repository", { "full_name" => name }, scope_key: name))
      normalizer.call(source_record("commit_files", "github:#{name}:commit:same-sha", detail, scope_key: name))
    end

    expect(Devdash::Models::Commit.where(sha: "same-sha").count).to eq(2)
    expect(Devdash::Models::Commit.where(parent_count: 2, default_branch_reachable: true).count).to eq(2)
    expect(Devdash::Models::CommitFile.count).to eq(2)
  end

  it "deletes only provisional GitHub identities that become unreferenced" do
    normalizer = described_class.new
    provisional = Devdash::Models::Person.create!(display_name: "provisional")
    Devdash::Models::SourceIdentity.create!(person: provisional, source: "github", external_id: "old", resolution_method: "provisional")
    manual = Devdash::Models::Person.create!(display_name: "manual")
    Devdash::Models::SourceIdentity.create!(person: manual, source: "github", external_id: "manual", resolution_method: "manual")
    Devdash::Models::SourceIdentity.create!(person: manual, source: "slack", external_id: "slack-1", resolution_method: "manual")
    normalizer.reset!

    expect(Devdash::Models::Person.where(id: provisional.id)).to be_empty
    expect(Devdash::Models::SourceIdentity.where(source: "github", external_id: "manual")).to exist
    expect(Devdash::Models::Person.where(id: manual.id)).to exist
  end

  def source_record(entity_type, external_id, payload, scope_key: "o/r")
    run = Devdash::Models::CollectorRun.create!(source: "github", scope_key:, status: "succeeded", started_at: Time.utc(2026, 1, 4))
    Devdash::Models::SourceRecord.create!(collector_run: run, source: "github", scope_key:, entity_type:, external_id:, observed_at: Time.utc(2026, 1, 4), source_updated_at: Time.utc(2026, 1, 3), query_fingerprint: "test", payload_hash: SecureRandom.hex(8), payload_json: JSON.generate(payload))
  end
end
