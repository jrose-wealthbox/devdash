# frozen_string_literal: true
require "devdash/sources/github/normalizer"
require "securerandom"

RSpec.describe Devdash::Sources::Github::Normalizer do
  before { connect_test_database! }

  it "registers both canonical and legacy pull request event entity types" do
    expect(Devdash::Normalizers::Registry.fetch(source: "github", entity_type: "pull_request_events"))
      .to be(Devdash::Sources::Github::NORMALIZER)
    expect(Devdash::Normalizers::Registry.fetch(source: "github", entity_type: "pull_request_timeline"))
      .to be(Devdash::Sources::Github::NORMALIZER)
  end

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

  it "preserves owners, merged people, and other protected references during reset" do
    normalizer = described_class.new
    owner = Devdash::Models::Person.create!(display_name: "owner", owner: true)
    Devdash::Models::SourceIdentity.create!(person: owner, source: "github", external_id: "owner", resolution_method: "provisional")

    destination = Devdash::Models::Person.create!(display_name: "destination")
    merged = Devdash::Models::Person.create!(display_name: "merged", merged_into: destination)
    Devdash::Models::SourceIdentity.create!(person: merged, source: "github", external_id: "merged", resolution_method: "unresolved")

    role_protected = Devdash::Models::Person.create!(display_name: "role-protected")
    Devdash::Models::SourceIdentity.create!(person: role_protected, source: "github", external_id: "role-protected", resolution_method: "provisional")
    Devdash::Models::RoleAssignment.create!(
      person: role_protected, source: "slack", original_title: "Engineer", effective_from: Time.utc(2026, 1, 1), observed_at: Time.utc(2026, 1, 1)
    )
    Devdash::Models::RoleAssignment.create!(
      person: role_protected, source: "github", original_title: "Contributor", effective_from: Time.utc(2026, 1, 1), observed_at: Time.utc(2026, 1, 1)
    )

    [owner, destination, merged, role_protected].each do |person|
      expect { person.reload }.not_to raise_error
    end
    expect { normalizer.reset! }.not_to change(Devdash::Models::Person, :count)
    expect(Devdash::Models::SourceIdentity.where(source: "github").count).to eq(3)
    expect(Devdash::Models::RoleAssignment.where(source: "github")).to be_empty
    expect(Devdash::Models::RoleAssignment.where(source: "slack")).to exist
  end

  it "uses source record timestamps and retains email evidence on identity updates" do
    normalizer = described_class.new
    normalizer.call(source_record("repository", "github:o/r:repository", { "full_name" => "o/r" }))
    first_observed_at = Time.utc(2026, 1, 1, 12)
    second_observed_at = Time.utc(2026, 1, 3, 12)
    first_payload = commit_payload(email: "dev@example.test", sha: "sha")
    second_payload = commit_payload(email: nil, sha: "sha")

    normalizer.call(source_record("commit_files", "github:o/r:commit:sha", first_payload,
      observed_at: first_observed_at, source_updated_at: Time.utc(2026, 1, 1)))
    identity = Devdash::Models::SourceIdentity.find_by!(source: "github", external_id: "dev")
    identity.update!(resolution_method: "manual")

    normalizer.call(source_record("commit_files", "github:o/r:commit:sha-2", second_payload,
      observed_at: second_observed_at, source_updated_at: Time.utc(2026, 1, 3)))

    expect(identity.reload).to have_attributes(
      first_observed_at: first_observed_at, last_observed_at: second_observed_at,
      normalized_email: "dev@example.test", resolution_method: "manual"
    )
    expect(Devdash::Models::Commit.find_by!(sha: "sha").author_email).to eq("dev@example.test")
  end

  it "does not merge a changed login through shared email evidence" do
    normalizer = described_class.new
    observed_at = Time.utc(2026, 1, 4)

    original_person = normalizer.send(:person, "old-login", email: "person@example.test", observed_at: observed_at)
    replacement_person = normalizer.send(:person, "new-login", email: "person@example.test", observed_at: observed_at + 1)

    expect(replacement_person).not_to eq(original_person)
    expect(Devdash::Models::SourceIdentity.where(source: "github").pluck(:external_id))
      .to contain_exactly("old-login", "new-login")
    expect(Devdash::Models::SourceIdentity.find_by!(source: "github", external_id: "old-login"))
      .to have_attributes(login: "old-login", normalized_email: "person@example.test")
  end

  it "does not attach email-only evidence to an ambiguous email match" do
    normalizer = described_class.new
    first = Devdash::Models::Person.create!(display_name: "first")
    second = Devdash::Models::Person.create!(display_name: "second")
    Devdash::Models::SourceIdentity.create!(
      person: first, source: "github", external_id: "shared@example.test",
      normalized_email: "shared@example.test", resolution_method: "provisional"
    )
    Devdash::Models::SourceIdentity.create!(
      person: second, source: "github", external_id: "second-login", login: "second-login",
      normalized_email: "shared@example.test", resolution_method: "provisional"
    )

    expect(normalizer.send(:person, nil, email: " shared@example.test ", observed_at: Time.utc(2026, 1, 4))).to be_nil
    expect(Devdash::Models::SourceIdentity.where(source: "github").pluck(:external_id))
      .to contain_exactly("shared@example.test", "second-login")
    expect(Devdash::Models::SourceIdentity.where(source: "github").pluck(:person_id))
      .to contain_exactly(first.id, second.id)
  end

  it "matches unique email-only evidence without changing the existing login identity" do
    normalizer = described_class.new
    person = normalizer.send(:person, "stable-login", email: "stable@example.test", observed_at: Time.utc(2026, 1, 1))

    expect(normalizer.send(:person, nil, email: " stable@example.test ", observed_at: Time.utc(2026, 1, 2)))
      .to eq(person)
    expect(Devdash::Models::SourceIdentity.find_by!(source: "github", external_id: "stable-login"))
      .to have_attributes(login: "stable-login", external_id: "stable-login", normalized_email: "stable@example.test")
    expect(Devdash::Models::SourceIdentity.where(source: "github").count).to eq(1)
  end

  it "strips sparse login and email evidence before retaining it" do
    normalizer = described_class.new
    normalizer.call(source_record("repository", "github:o/r:repository", { "full_name" => "o/r" }))
    pull_payload = { "number" => 42, "node_id" => "pr-42", "state" => "open", "user" => { "login" => "  dev  " } }
    normalizer.call(source_record("pull_request", "github:o/r:pull:42", pull_payload))

    commit = commit_payload(email: "  DEV@Example.Test  ", sha: "sha", login: "  dev  ")
    normalizer.call(source_record("commit_files", "github:o/r:commit:sha", commit))

    pull_request = Devdash::Models::PullRequest.find_by!(number: 42)
    commit_record = Devdash::Models::Commit.find_by!(sha: "sha")
    expect(pull_request).to have_attributes(author_login: "dev")
    expect(commit_record).to have_attributes(
      author_login: "dev", author_email: "dev@example.test",
      committer_login: "dev", committer_email: "dev@example.test"
    )
    expect(Devdash::Models::SourceIdentity.find_by!(source: "github", external_id: "dev"))
      .to have_attributes(login: "dev", normalized_email: "dev@example.test")
  end

  def source_record(entity_type, external_id, payload, scope_key: "o/r", observed_at: Time.utc(2026, 1, 4), source_updated_at: Time.utc(2026, 1, 3))
    run = Devdash::Models::CollectorRun.create!(source: "github", scope_key:, status: "succeeded", started_at: Time.utc(2026, 1, 4))
    Devdash::Models::SourceRecord.create!(collector_run: run, source: "github", scope_key:, entity_type:, external_id:, observed_at:, source_updated_at:, query_fingerprint: "test", payload_hash: SecureRandom.hex(8), payload_json: JSON.generate(payload))
  end

  def commit_payload(email:, sha:, login: "dev")
    {
      "sha" => sha, "author" => { "login" => login }, "committer" => { "login" => login },
      "commit" => {
        "author" => { "email" => email, "date" => "2026-01-01T00:00:00Z" },
        "committer" => { "email" => email, "date" => "2026-01-01T01:00:00Z" }
      },
      "parents" => [], "files" => []
    }
  end
end
