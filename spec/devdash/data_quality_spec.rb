# frozen_string_literal: true

require "digest"
require "json"
require "spec_helper"

RSpec.describe "dashboard data quality invariants" do
  before { connect_test_database! }

  def source_record(source:, scope_key:, entity_type:, external_id:, payload:, observed_at: Time.utc(2026, 9, 3))
    run = Devdash::Models::CollectorRun.create!(source:, scope_key:, status: "succeeded", started_at: observed_at,
      finished_at: observed_at)
    json = Devdash::Ingestion::CanonicalJson.dump(payload)
    Devdash::Models::SourceRecord.create!(collector_run: run, source:, scope_key:, entity_type:, external_id:,
      observed_at:, query_fingerprint: "fixture", payload_hash: Digest::SHA256.hexdigest(json), payload_json: json)
  end

  it "retains an observation for every canonical source fact and preserves canonical JSON hashes" do
    repository = Devdash::Models::Repository.create!(source: "github", full_name: "acme/crm-web", alias_name: "crm-web")
    source = source_record(source: "github", scope_key: repository.full_name, entity_type: "repository",
      external_id: "github:acme/crm-web:repository", payload: { "full_name" => repository.full_name })
    expect(Devdash::Models::SourceRecord.find_by!(source: "github", external_id: source.external_id)).to be_present
    expect(source.payload_hash).to eq(Digest::SHA256.hexdigest(source.payload_json))

    # Typed canonical tables may retain only normalized fields; they must not
    # become a second, undocumented payload store.
    expect(Dir[File.join(Devdash.root, "lib/devdash/metrics/**/*.rb")].flat_map { |file| File.readlines(file) }
      .grep(/payload_json/)).to be_empty
  end

  it "rejects edits to evidence columns while allowing replay to stamp normalizer version" do
    source = source_record(source: "slack", scope_key: "workspace", entity_type: "user", external_id: "U1",
      payload: { "id" => "U1", "name" => "Ada" })

    expect { source.update!(payload_json: "tampered") }
      .to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { source.update!(normalizer_version: 3) }.not_to raise_error
    expect(source.reload.normalizer_version).to eq(3)
  end

  it "passes foreign-key checks and prevents duplicate domain keys" do
    Devdash::Models::Repository.create!(source: "github", full_name: "acme/crm-web", alias_name: "crm-web")
    expect do
      Devdash::Models::Repository.create!(source: "github", full_name: "acme/crm-web", alias_name: "crm-copy")
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(ActiveRecord::Base.connection.select_values("PRAGMA foreign_key_check")).to be_empty
  end

  it "has one configured default and no overlapping role evidence intervals" do
    config = Devdash::Configuration.new(raw: {
      "database_path" => ":memory:", "github" => { "repositories" => [
        { "name" => "acme/crm-web", "alias" => "crm-web", "default" => true },
        { "name" => "acme/other", "alias" => "other", "default" => false }
      ] }
    }, config_path: "config/devdash.yml")
    expect(config.repositories.count(&:default)).to eq(1)

    person = Devdash::Models::Person.create!(display_name: "Ada")
    Devdash::Models::RoleAssignment.create!(person:, source: "slack", original_title: "Engineer",
      normalized_role: "software_engineer", normalized_level: "senior",
      effective_from: Time.utc(2026, 1, 1), effective_until: Time.utc(2026, 6, 1), observed_at: Time.utc(2026, 1, 1))
    Devdash::Models::RoleAssignment.create!(person:, source: "slack", original_title: "Staff Engineer",
      normalized_role: "software_engineer", normalized_level: "staff",
      effective_from: Time.utc(2026, 6, 1), effective_until: nil, observed_at: Time.utc(2026, 6, 1))

    overlaps = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT COUNT(*) FROM role_assignments a
      JOIN role_assignments b ON a.person_id = b.person_id
        AND a.source = b.source AND a.id < b.id
        AND a.effective_from < COALESCE(b.effective_until, '9999-12-31')
        AND b.effective_from < COALESCE(a.effective_until, '9999-12-31')
    SQL
    expect(overlaps.to_i).to eq(0)
  end

  it "stores reconstructable report semantic inputs without secret-shaped values" do
    snapshot = Devdash::Models::ReportSnapshot.create!(
      cache_key: "fixture-cache", window_start_at: Time.utc(2026, 8, 27), window_end_at: Time.utc(2026, 9, 3),
      repository_scope_hash: "scope", cohort_hash: "cohort", metric_versions_hash: "metrics",
      source_watermark_hash: "watermark", format_version: 1, structured_json: '{"value":1}', rendered_text: "value"
    )
    expect(snapshot).to have_attributes(window_start_at: Time.utc(2026, 8, 27), window_end_at: Time.utc(2026, 9, 3),
      repository_scope_hash: "scope", cohort_hash: "cohort", metric_versions_hash: "metrics", source_watermark_hash: "watermark")
    text = ActiveRecord::Base.connection.select_values("SELECT structured_json || COALESCE(rendered_text, '') FROM report_snapshots").join
    expect(text).not_to match(/(?:bearer|token|api[_-]?key|password)\s*[:=]/i)
  end
end
