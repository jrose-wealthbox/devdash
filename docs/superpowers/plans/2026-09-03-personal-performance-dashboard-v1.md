# Personal Performance Dashboard V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a private local Ruby CLI that idempotently collects lossless GitHub, Linear, and Slack evidence, normalizes it into SQLite, and reports repository-scoped 7/30/180-day personal and peer comparisons.

**Architecture:** The application has three rebuildable persistence layers: immutable source observations, normalized canonical domain tables/events, and disposable metric/report caches. Deterministic transports feed source-specific collectors through a shared transactional ingestion contract; reports query only canonical tables and use a versioned metric registry. Repository scope, cohort identity, provenance, and coverage are first-class inputs to collection and reporting.

**Tech Stack:** Ruby 4.0.1 via mise; Active Record 8.1.3.1; SQLite/sqlite3 2.9.6; RSpec 3.13.2; WebMock 3.26.4; Ruby standard-library `OptionParser`, `Open3`, `Net::HTTP`, `JSON`, `YAML`, `Digest`, and `Time`.

## Global Constraints

- Run every Ruby, Bundler, executable, and RSpec command through `mise exec --`; macOS system Ruby 2.6 is not a valid execution environment.
- Preserve `mise.toml` exactly as supplied: `[tools]` with `ruby = "4.0.1"`.
- Keep all source credentials outside SQLite and Git; read them from environment variables or the OS credential store.
- `devdash report`, `devdash reprocess`, and `devdash rebuild-derived` must make zero network or `gh` calls.
- Preserve every field returned by configured API queries in immutable, content-addressed `source_records`; never store authorization headers or tokens.
- Query reports through typed normalized columns and relations, never directly through raw payload JSON.
- Treat metric/report rows as disposable caches; every cache key includes metric version, repository-scope hash, cohort hash, source watermark, and format version.
- Store timestamps in UTC and use half-open report windows `[start_at, end_at)`.
- Support multiple explicitly configured GitHub repositories, exactly one enabled default, and the virtual `all` scope.
- Label `all` as `All configured repos (N)`; it never implies every repository in the GitHub organization.
- Keep GitHub cursor/coverage state repository-qualified. Slack and Linear remain global source scopes.
- Deduplicate GitHub reviews by review ID; line comments are not additional reviews.
- Label Linear completions as “completed while assigned”; never infer transition authorship when Linear omits it.
- Store raw, canonical, and derived data locally under ignored paths with owner-only permissions where supported.
- Slack V1 collection is limited to identities and profile titles; do not collect messages.
- Use TDD for every behavior: observe the specified failure before implementation, then run focused and full tests.
- Stage only paths owned by the current task. Preserve unrelated/user-authored changes, especially `mise.toml` until Task 1 adopts it.

## File and Ownership Map

| Area | Files | Responsibility |
|---|---|---|
| Bootstrap | `mise.toml`, `Gemfile`, `Gemfile.lock`, `.gitignore`, `.rspec`, `bin/devdash`, `bin/setup`, `lib/devdash.rb` | Runtime, dependencies, executable entrypoints |
| Configuration | `lib/devdash/configuration.rb`, `lib/devdash/repository_scope.rb`, `config/devdash.example.yml` | Validate repository/source configuration and resolve default/single/`all` scopes |
| Persistence | `lib/devdash/database.rb`, `lib/devdash/models/*.rb`, `db/migrate/*.rb` | Active Record setup, migrations, canonical models |
| Evidence ingestion | `lib/devdash/ingestion/*.rb`, `lib/devdash/normalizers/registry.rb` | Canonical JSON, immutable evidence, transactions, cursors, coverage |
| Replay | `lib/devdash/reprocessing/*.rb` | Offline canonical replay and derived-cache rebuild |
| Transports | `lib/devdash/transports/*.rb` | Shell-free command invocation and read-only HTTP/JSON pagination |
| Slack | `lib/devdash/sources/slack/*.rb`, `spec/fixtures/slack/*` | Workspace people/title evidence and normalization |
| GitHub | `lib/devdash/sources/github/*.rb`, `spec/fixtures/github/*` | Repository, PR, review, event, commit, and file-stat evidence/normalization |
| Linear | `lib/devdash/sources/linear/*.rb`, `spec/fixtures/linear/*` | Issue/history/link evidence and normalization |
| Identity | `lib/devdash/identity/*.rb`, `config/people.example.yml` | Cross-source people, title normalization, effective-dated cohorts |
| Metrics | `lib/devdash/metrics/*.rb`, `lib/devdash/metrics/github/*.rb`, `lib/devdash/metrics/linear/*.rb` | Versioned definitions, windows, statistics, source-specific queries |
| Reporting | `lib/devdash/reporting/*.rb` | EngThrive/SPACE/DevEx-organized terminal output and cache snapshots |
| Orchestration | `lib/devdash/commands/*.rb`, `lib/devdash/sync_runner.rb`, `lib/devdash/doctor.rb` | CLI commands, source coordination, diagnostics |

## Dependency Graph and Delegation

```text
Sequential foundation:
  T1 Bootstrap/config
    -> T2 Schema/models
      -> T3 Evidence ingestion
        -> T4 Transports + offline replay contracts

Parallel wave A (three isolated Luna worktrees from T4):
  T5 Slack collector -----\
  T6 GitHub collector ------> merge/review gate -> T8 Identity/cohort/linking
  T7 Linear collector -----/

Sequential metric core:
  T8 -> T9 Metric registry/comparison core

Parallel wave B (two isolated Luna worktrees from T9):
  T10 GitHub metrics ----\
  T11 Linear metrics -----> merge/review gate -> T12 Reporting/CLI

Sequential acceptance:
  T12 -> T13 End-to-end hardening and documentation
```

Use `gpt-5.6-luna` for implementation subagents as requested. At execution time, first invoke `superpowers:subagent-driven-development`, then create each worktree through `superpowers:using-git-worktrees`. The root agent performs spec-compliance review followed by code-quality review before merging each task.

Tasks 1–4, 8–9, and 12–13 are sequential because they define or integrate shared interfaces. Tasks 5–7 are intentionally file-disjoint and can use all three available Luna slots. Tasks 10–11 are also file-disjoint after Task 9 freezes the metric interface. Do not parallelize migrations or shared-interface changes outside those declared waves.

---


### Task 1: Bootstrap, configuration, and repository scopes

**Files:**
- Adopt: `mise.toml`
- Create: `Gemfile`
- Create: `Gemfile.lock`
- Create: `.gitignore`
- Create: `.rspec`
- Create: `bin/setup`
- Create: `bin/devdash`
- Create: `lib/devdash.rb`
- Create: `lib/devdash/configuration.rb`
- Create: `lib/devdash/repository_scope.rb`
- Create: `config/devdash.example.yml`
- Create: `spec/spec_helper.rb`
- Create: `spec/devdash/configuration_spec.rb`
- Create: `spec/devdash/repository_scope_spec.rb`
- Create: `spec/devdash/cli_smoke_spec.rb`

**Interfaces:**
- Consumes: existing `mise.toml` with Ruby 4.0.1.
- Produces: `Devdash.root`, `Devdash::Configuration.load(path:)`, `Configuration#resolve_repository_scope(selector = nil)`, and immutable `Devdash::RepositoryScope` with `key`, `repository_names`, `label`, and `configuration_hash`.

- [ ] **Step 1: Verify the pinned runtime and adopt the project dependencies**

Keep `mise.toml` unchanged. Create this `Gemfile`:

```ruby
source "https://rubygems.org"

ruby "4.0.1"

gem "activerecord", "8.1.3.1"
gem "sqlite3", "~> 2.9.6"

group :development, :test do
  gem "rspec", "~> 3.13.2"
  gem "webmock", "~> 3.26.4"
end
```

Run:

```bash
mise exec -- ruby -v
mise exec -- bundle install
```

Expected: Ruby reports `4.0.1`; Bundler resolves and writes `Gemfile.lock`. If dependency installation needs network approval, request it rather than using host gems.

- [ ] **Step 2: Create test/bootstrap files**

Create `.rspec`:

```text
--require spec_helper
--format documentation
--order random
```

Create `spec/spec_helper.rb`:

```ruby
# frozen_string_literal: true

require "tmpdir"
require "webmock/rspec"
require_relative "../lib/devdash"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.example_status_persistence_file_path = "tmp/rspec-examples.txt"
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.filter_run_when_matching :focus
end

WebMock.disable_net_connect!(allow_localhost: true)
```

Create `lib/devdash.rb`:

```ruby
# frozen_string_literal: true

require "pathname"

module Devdash
  class Error < StandardError; end
  class ConfigurationError < Error; end

  def self.root
    @root ||= Pathname(__dir__).join("..").expand_path
  end
end

require_relative "devdash/repository_scope"
require_relative "devdash/configuration"
```

Create `.gitignore` with these exact runtime paths:

```gitignore
/.bundle/
/vendor/bundle/
/tmp/
/data/*.sqlite3
/data/*.sqlite3-*
/config/devdash.yml
/config/people.yml
/.env
```

- [ ] **Step 3: Write failing repository-configuration specs**

In `spec/devdash/configuration_spec.rb`, cover the full configuration contract:

```ruby
# frozen_string_literal: true

RSpec.describe Devdash::Configuration do
  def write_config(directory, yaml)
    path = File.join(directory, "devdash.yml")
    File.write(path, yaml)
    path
  end

  let(:valid_yaml) do
    <<~YAML
      database_path: data/devdash.sqlite3
      github:
        repositories:
          - name: starburstlabs/crm-web
            alias: crm-web
            default: true
            enabled: true
          - name: starburstlabs/repo1
            alias: repo1
            enabled: true
    YAML
  end

  it "requires exactly one enabled default repository" do
    Dir.mktmpdir do |directory|
      path = write_config(directory, valid_yaml.gsub("default: true", "default: false"))
      expect { described_class.load(path:) }
        .to raise_error(Devdash::ConfigurationError, /exactly one enabled default/)
    end
  end

  it "rejects duplicate and reserved aliases" do
    Dir.mktmpdir do |directory|
      duplicate = valid_yaml.sub("alias: repo1", "alias: crm-web")
      expect { described_class.load(path: write_config(directory, duplicate)) }
        .to raise_error(Devdash::ConfigurationError, /unique/)

      reserved = valid_yaml.sub("alias: repo1", "alias: all")
      expect { described_class.load(path: write_config(directory, reserved)) }
        .to raise_error(Devdash::ConfigurationError, /reserved/)
    end
  end

  it "resolves omitted, named, fully-qualified, and all scopes" do
    Dir.mktmpdir do |directory|
      config = described_class.load(path: write_config(directory, valid_yaml))
      expect(config.resolve_repository_scope.repository_names)
        .to eq(["starburstlabs/crm-web"])
      expect(config.resolve_repository_scope("repo1").repository_names)
        .to eq(["starburstlabs/repo1"])
      expect(config.resolve_repository_scope("starburstlabs/repo1").key)
        .to eq("repo1")
      expect(config.resolve_repository_scope("all").repository_names)
        .to eq(["starburstlabs/crm-web", "starburstlabs/repo1"])
      expect(config.resolve_repository_scope("all").label)
        .to eq("All configured repos (2)")
    end
  end
end
```

Run:

```bash
mise exec -- bundle exec rspec spec/devdash/configuration_spec.rb
```

Expected: FAIL with `uninitialized constant Devdash::Configuration` or missing methods.

- [ ] **Step 4: Implement immutable repository configuration and scope resolution**

Implement `lib/devdash/repository_scope.rb`:

```ruby
# frozen_string_literal: true

require "digest"
require "json"

module Devdash
  RepositoryScope = Data.define(:key, :repository_names, :label, :configuration_hash)
end
```

Implement `lib/devdash/configuration.rb` with these public records and methods:

```ruby
# frozen_string_literal: true

require "yaml"

module Devdash
  class Configuration
    Repository = Data.define(:name, :alias_name, :default, :enabled)

    attr_reader :database_path, :repositories

    def self.load(path: Devdash.root.join("config/devdash.yml"))
      raw = YAML.safe_load_file(path.to_s, permitted_classes: [], aliases: false)
      new(raw:, config_path: Pathname(path))
    rescue Errno::ENOENT => error
      raise ConfigurationError, "configuration not found: #{error.message}"
    rescue Psych::Exception => error
      raise ConfigurationError, "invalid YAML: #{error.message}"
    end

    def initialize(raw:, config_path:)
      @config_path = config_path
      @database_path = expand_path(raw.fetch("database_path", "data/devdash.sqlite3"))
      @repositories = Array(raw.dig("github", "repositories")).map do |item|
        Repository.new(
          name: item.fetch("name"),
          alias_name: item.fetch("alias"),
          default: item.fetch("default", false),
          enabled: item.fetch("enabled", true)
        )
      end.freeze
      validate!
    end

    def resolve_repository_scope(selector = nil)
      enabled = repositories.select(&:enabled)
      selected = selector || enabled.find(&:default).alias_name
      members = if selected == "all"
        enabled
      else
        [enabled.find { |repository| [repository.alias_name, repository.name].include?(selected) } ||
          raise(ConfigurationError, "unknown or disabled repository: #{selected}")]
      end
      names = members.map(&:name).sort.freeze
      label = selected == "all" ? "All configured repos (#{names.length})" : members.fetch(0).alias_name
      RepositoryScope.new(
        key: selected == "all" ? "all" : members.fetch(0).alias_name,
        repository_names: names,
        label:,
        configuration_hash: Digest::SHA256.hexdigest(JSON.generate(names))
      )
    end

    private

    def expand_path(value)
      Pathname(value).absolute? ? Pathname(value) : Devdash.root.join(value)
    end

    def validate!
      enabled = repositories.select(&:enabled)
      raise ConfigurationError, "exactly one enabled default repository is required" unless enabled.count(&:default) == 1
      aliases = repositories.map(&:alias_name)
      raise ConfigurationError, "repository aliases must be unique" unless aliases.uniq.length == aliases.length
      raise ConfigurationError, "repository alias 'all' is reserved" if aliases.include?("all")
      invalid = repositories.reject { |repository| repository.name.match?(%r{\A[^/]+/[^/]+\z}) }
      raise ConfigurationError, "repository names must use owner/name" if invalid.any?
    end
  end
end
```

Run the focused spec; expected: PASS.

- [ ] **Step 5: Add executable smoke behavior and example configuration**

Create `bin/devdash`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/devdash"

if ["-h", "--help"].include?(ARGV.first) || ARGV.empty?
  puts "Usage: devdash COMMAND [options]"
  puts "Commands: sync, backfill, report, reprocess, rebuild-derived, doctor"
  exit 0
end

warn "Unknown command: #{ARGV.first}"
exit 64
```

Create `bin/setup`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mise exec -- bundle install
mkdir -p data tmp
mise exec -- bundle exec ruby bin/devdash --help
```

Create `config/devdash.example.yml` using the exact `crm-web`, `repo1`, and `repo2` structure from the design. Add a smoke spec that invokes `mise exec -- ruby bin/devdash --help` with `Open3.capture3` and expects exit 0 plus `Usage:`. Mark both scripts executable.

Run:

```bash
chmod +x bin/devdash bin/setup
mise exec -- bundle exec rspec
```

Expected: all Task 1 examples pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add mise.toml Gemfile Gemfile.lock .gitignore .rspec bin/setup bin/devdash lib/devdash.rb lib/devdash/configuration.rb lib/devdash/repository_scope.rb config/devdash.example.yml spec/spec_helper.rb spec/devdash
git commit -m "Bootstrap Devdash configuration and repository scopes"
```

---

### Task 2: SQLite foundation schema and canonical models

**Files:**
- Modify: `bin/setup`
- Create: `lib/devdash/database.rb`
- Create: `lib/devdash/models/base_record.rb`
- Create: `lib/devdash/models/organization.rb`
- Create: `lib/devdash/models/person.rb`
- Create: `lib/devdash/models/person_merge_audit.rb`
- Create: `lib/devdash/models/source_identity.rb`
- Create: `lib/devdash/models/role_assignment.rb`
- Create: `lib/devdash/models/repository.rb`
- Create: `lib/devdash/models/collector_run.rb`
- Create: `lib/devdash/models/collector_run_coverage.rb`
- Create: `lib/devdash/models/sync_cursor.rb`
- Create: `lib/devdash/models/source_record.rb`
- Create: `lib/devdash/models/normalization_run.rb`
- Create: `db/migrate/001_create_foundation.rb`
- Create: `spec/support/database.rb`
- Create: `spec/devdash/database_spec.rb`
- Create: `spec/devdash/models/foundation_spec.rb`

**Interfaces:**
- Consumes: `Devdash.root`, `Configuration#database_path` from Task 1.
- Produces: `Devdash::Database.connect!(path:)`, `Database.migrate!`, `Database.with_connection`, and namespaced Active Record models under `Devdash::Models`.

- [ ] **Step 1: Write the failing database lifecycle spec**

Create `spec/support/database.rb` with `connect_test_database!` that uses a unique `Dir.mktmpdir` SQLite path, calls `Database.connect!`, and calls `Database.migrate!`. Require it from `spec_helper.rb`.

Create `spec/devdash/database_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Devdash::Database do
  it "migrates an empty SQLite database and enables foreign keys" do
    connect_test_database!
    tables = ActiveRecord::Base.connection.tables
    expect(tables).to include("people", "source_records", "sync_cursors")
    expect(ActiveRecord::Base.connection.select_value("PRAGMA foreign_keys")).to eq(1)
  end

  it "enforces one external identity per source ID" do
    connect_test_database!
    person = Devdash::Models::Person.create!(display_name: "John", human: true, owner: true)
    attributes = { person:, source: "github", external_id: "U_1", login: "john" }
    Devdash::Models::SourceIdentity.create!(attributes)
    expect { Devdash::Models::SourceIdentity.create!(attributes) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
```

Run:

```bash
mise exec -- bundle exec rspec spec/devdash/database_spec.rb
```

Expected: FAIL because `Devdash::Database` is undefined.

- [ ] **Step 2: Implement connection and migration helpers**

Implement `lib/devdash/database.rb`:

```ruby
# frozen_string_literal: true

require "active_record"
require "fileutils"

module Devdash
  module Database
    module_function

    def connect!(path:)
      FileUtils.mkdir_p(File.dirname(path.to_s), mode: 0o700)
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: path.to_s)
      connection = ActiveRecord::Base.connection
      connection.execute("PRAGMA foreign_keys = ON")
      connection.execute("PRAGMA journal_mode = WAL") unless path.to_s == ":memory:"
      connection.execute("PRAGMA busy_timeout = 5000")
      connection
    end

    def migrate!
      pool = ActiveRecord::Base.connection_pool
      ActiveRecord::MigrationContext.new(
        [Devdash.root.join("db/migrate").to_s],
        pool.schema_migration,
        pool.internal_metadata
      ).migrate
    end

    def with_connection(&block)
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end
end
```

Require `database` and model files from `lib/devdash.rb` after `Configuration`.

- [ ] **Step 3: Create the complete foundation migration**

Implement `db/migrate/001_create_foundation.rb` as `ActiveRecord::Migration[8.1]`. Create these tables and constraints exactly:

```ruby
create_table :organizations do |t|
  t.string :name, null: false
  t.timestamps
end

create_table :people do |t|
  t.references :organization, foreign_key: true
  t.references :merged_into, foreign_key: { to_table: :people }
  t.string :display_name, null: false
  t.boolean :active, null: false, default: true
  t.boolean :human, null: false, default: true
  t.boolean :bot, null: false, default: false
  t.boolean :guest, null: false, default: false
  t.boolean :owner, null: false, default: false
  t.timestamps
end
add_index :people, :owner, unique: true, where: "owner = 1"

create_table :source_identities do |t|
  t.references :person, null: false, foreign_key: true
  t.string :source, null: false
  t.string :external_id, null: false
  t.string :login
  t.string :normalized_email
  t.string :observed_display_name
  t.string :resolution_method, null: false, default: "unresolved"
  t.decimal :confidence, precision: 4, scale: 3
  t.datetime :first_observed_at, null: false
  t.datetime :last_observed_at, null: false
  t.timestamps
end
add_index :source_identities, %i[source external_id], unique: true

create_table :role_assignments do |t|
  t.references :person, null: false, foreign_key: true
  t.string :source, null: false
  t.string :original_title, null: false
  t.string :normalized_role
  t.string :normalized_level
  t.datetime :effective_from, null: false
  t.datetime :effective_until
  t.datetime :observed_at, null: false
  t.timestamps
end

create_table :repositories do |t|
  t.string :source, null: false, default: "github"
  t.string :external_id
  t.string :full_name, null: false
  t.string :alias_name, null: false
  t.string :default_branch
  t.boolean :enabled, null: false, default: true
  t.boolean :default_report, null: false, default: false
  t.boolean :archived, null: false, default: false
  t.text :metadata_json
  t.timestamps
end
add_index :repositories, :full_name, unique: true
add_index :repositories, :alias_name, unique: true
add_index :repositories, :default_report, unique: true, where: "default_report = 1"

create_table :collector_runs do |t|
  t.string :source, null: false
  t.string :scope_key, null: false
  t.string :status, null: false
  t.datetime :started_at, null: false
  t.datetime :finished_at
  t.string :cursor_before
  t.string :cursor_after
  t.integer :page_count, null: false, default: 0
  t.integer :record_count, null: false, default: 0
  t.integer :retry_count, null: false, default: 0
  t.string :error_class
  t.text :error_message
  t.timestamps
end

create_table :collector_run_coverages do |t|
  t.references :collector_run, null: false, foreign_key: true
  t.string :scope_type, null: false
  t.string :scope_key, null: false
  t.string :entity_type, null: false
  t.datetime :requested_start_at
  t.datetime :requested_end_at
  t.datetime :achieved_start_at
  t.datetime :achieved_end_at
  t.string :status, null: false
  t.timestamps
end

create_table :sync_cursors do |t|
  t.string :source, null: false
  t.string :scope_key, null: false
  t.string :cursor_type, null: false
  t.text :cursor_value
  t.datetime :last_succeeded_at
  t.timestamps
end
add_index :sync_cursors, %i[source scope_key cursor_type], unique: true

create_table :source_records do |t|
  t.references :collector_run, null: false, foreign_key: true
  t.string :source, null: false
  t.string :scope_key, null: false
  t.string :entity_type, null: false
  t.string :external_id, null: false
  t.datetime :source_updated_at
  t.datetime :observed_at, null: false
  t.string :api_version
  t.string :query_fingerprint, null: false
  t.integer :normalizer_version
  t.string :payload_hash, null: false
  t.text :payload_json, null: false
  t.timestamps
end
add_index :source_records,
  %i[source scope_key entity_type external_id payload_hash],
  unique: true,
  name: "idx_source_records_identity_and_hash"

create_table :normalization_runs do |t|
  t.string :normalizer_key, null: false
  t.integer :normalizer_version, null: false
  t.integer :source_record_watermark
  t.string :status, null: false
  t.datetime :started_at, null: false
  t.datetime :finished_at
  t.integer :input_count, null: false, default: 0
  t.integer :output_count, null: false, default: 0
  t.string :error_class
  t.text :error_message
  t.timestamps
end
```

Also add `person_merge_audits` with `source_person_id`, `destination_person_id`, `reason`, `evidence_reference`, and `merged_at`; use explicit foreign keys with `on_delete: :restrict`. A merged source-person row is retained and points to `merged_into_id`, preserving the audit foreign key while all activity/identity facts move to the destination.

- [ ] **Step 4: Add focused model classes and associations**

Create `Devdash::Models::BaseRecord < ActiveRecord::Base` with `self.abstract_class = true`. Put each model in its own file. Define only associations and validations required by the migration; do not add callbacks. Example:

```ruby
module Devdash
  module Models
    class SourceRecord < BaseRecord
      belongs_to :collector_run

      validates :source, :scope_key, :entity_type, :external_id,
        :observed_at, :query_fingerprint, :payload_hash, :payload_json,
        presence: true
    end
  end
end
```

`Repository` validates full-name format, alias uniqueness, and rejects alias `all`. `CollectorRun` validates status inclusion in `running succeeded partial failed`. `CollectorRunCoverage` validates status inclusion in `complete partial failed`. Add association specs that create the complete graph and assert foreign-key failures for missing parents.

Make source evidence columns on `SourceRecord` read-only after insertion (`collector_run_id`, source/scope/entity/external identity, source/observation timestamps, API/query metadata, payload hash, and payload JSON). `normalizer_version` is deliberately mutable operational metadata and is the only source-record field replay updates.

- [ ] **Step 5: Complete setup behavior and run migration/model tests**

Update `bin/setup` so that after dependency installation it loads configuration, connects to the configured database, and calls `Devdash::Database.migrate!`. Keep test setup pointed at its unique temporary database.

```bash
mise exec -- bundle exec rspec spec/devdash/database_spec.rb spec/devdash/models/foundation_spec.rb
mise exec -- bundle exec rspec
```

Expected: all examples pass. Inspect `ActiveRecord::Base.connection.foreign_keys("source_records")` in the focused spec to prove enforcement rather than assuming it from model validations.

- [ ] **Step 6: Commit Task 2**

```bash
git add bin/setup lib/devdash.rb lib/devdash/database.rb lib/devdash/models db/migrate/001_create_foundation.rb spec/spec_helper.rb spec/support/database.rb spec/devdash/database_spec.rb spec/devdash/models/foundation_spec.rb
git commit -m "Add normalized persistence foundation"
```

---

### Task 3: Immutable evidence ingestion and transactional cursors

**Files:**
- Create: `lib/devdash/ingestion/canonical_json.rb`
- Create: `lib/devdash/ingestion/source_observation.rb`
- Create: `lib/devdash/ingestion/batch.rb`
- Create: `lib/devdash/ingestion/writer.rb`
- Create: `lib/devdash/normalizers/registry.rb`
- Create: `spec/devdash/ingestion/canonical_json_spec.rb`
- Create: `spec/devdash/ingestion/writer_spec.rb`
- Create: `spec/support/fake_normalizer.rb`

**Interfaces:**
- Consumes: foundation models from Task 2.
- Produces: `SourceObservation`, `Batch`, `NormalizerRegistry#register/#fetch/#each`, and `Writer#call(batch)` returning a succeeded `CollectorRun`.

- [ ] **Step 1: Write failing canonical-payload tests**

```ruby
RSpec.describe Devdash::Ingestion::CanonicalJson do
  it "sorts nested object keys without sorting arrays" do
    left = { "z" => [{ "b" => 2, "a" => 1 }], "a" => true }
    right = { "a" => true, "z" => [{ "a" => 1, "b" => 2 }] }
    expect(described_class.dump(left)).to eq(described_class.dump(right))
    expect(described_class.sha256(left)).to eq(described_class.sha256(right))
  end
end
```

Run the focused spec. Expected: FAIL because the constant is undefined.

- [ ] **Step 2: Implement canonical JSON and immutable value objects**

Implement recursive key sorting and `Digest::SHA256.hexdigest(dump(value))`. Define:

```ruby
SourceObservation = Data.define(
  :entity_type,
  :external_id,
  :source_updated_at,
  :observed_at,
  :api_version,
  :query_fingerprint,
  :payload
)

Batch = Data.define(
  :source,
  :scope_key,
  :cursor_type,
  :cursor_before,
  :cursor_after,
  :observations,
  :coverages,
  :page_count,
  :retry_count
)
```

Freeze a deep copy of payload hashes/arrays in `SourceObservation#initialize`; reject payloads containing case-insensitive keys matching `authorization`, `access_token`, `api_key`, or `x-api-key`.

- [ ] **Step 3: Write failing ingestion idempotency and rollback specs**

The spec must register a fake normalizer, ingest the same batch twice, and assert one `source_record` plus two succeeded run records. It must then configure the normalizer to raise after the first of two observations and assert:

```ruby
expect { writer.call(failing_batch) }.to raise_error(FakeNormalizer::Failure)
expect(Devdash::Models::SyncCursor.find_by(source: "fake", scope_key: "global").cursor_value)
  .to eq("cursor-1")
expect(Devdash::Models::SourceRecord.where(external_id: %w[two three])).to be_empty
expect(Devdash::Models::CollectorRun.order(:id).last.status).to eq("failed")
```

Run the focused spec. Expected: FAIL because `Writer` and `NormalizerRegistry` are undefined.

- [ ] **Step 4: Implement the normalizer registry and atomic writer**

`NormalizerRegistry#register(source:, entity_type:, normalizer:)` rejects duplicate keys. A normalizer responds to `version` and `call(source_record)`.

`Writer#call` performs this exact lifecycle:

1. Create a `running` collector run outside the ingestion transaction.
2. Verify `batch.cursor_before` equals the persisted cursor value; raise `StaleCursorError` on mismatch.
3. Inside one transaction, canonicalize every payload, `create_or_find_by!` the content-addressed `source_record`, run the registered normalizer for new records or records whose `normalizer_version` is stale, insert coverage rows, and upsert the cursor.
4. Mark the run `succeeded` with counts after commit.
5. On any exception, mark the run `failed` with sanitized class/message and re-raise.

The source-record insert attributes must use:

```ruby
payload_json = CanonicalJson.dump(observation.payload)
payload_hash = Digest::SHA256.hexdigest(payload_json)
identity = {
  source: batch.source,
  scope_key: batch.scope_key,
  entity_type: observation.entity_type,
  external_id: observation.external_id,
  payload_hash:
}
```

Do not rescue `ActiveRecord::RecordNotUnique` manually; use `create_or_find_by!` with the complete unique identity.

- [ ] **Step 5: Prove idempotency, cursor atomicity, and secret rejection**

```bash
mise exec -- bundle exec rspec spec/devdash/ingestion/canonical_json_spec.rb spec/devdash/ingestion/writer_spec.rb
mise exec -- bundle exec rspec
```

Expected: all examples pass, including a spec that spies on the fake normalizer and proves the second identical ingestion does not create a duplicate canonical fact.

- [ ] **Step 6: Commit Task 3**

```bash
git add lib/devdash/ingestion lib/devdash/normalizers spec/devdash/ingestion spec/support/fake_normalizer.rb
git commit -m "Add transactional evidence ingestion"
```

---

### Task 4: Deterministic transports and offline replay contracts

**Files:**
- Create: `lib/devdash/transports/errors.rb`
- Create: `lib/devdash/transports/command.rb`
- Create: `lib/devdash/transports/http_json.rb`
- Create: `lib/devdash/reprocessing/reprocessor.rb`
- Create: `lib/devdash/reprocessing/derived_rebuilder.rb`
- Create: `spec/devdash/transports/command_spec.rb`
- Create: `spec/devdash/transports/http_json_spec.rb`
- Create: `spec/devdash/reprocessing/reprocessor_spec.rb`

**Interfaces:**
- Consumes: ingestion registry and canonical models from Tasks 2–3.
- Produces: `Command#capture(*argv, env: {})`, `HttpJson#get(path:, query:, headers:)`, `Reprocessor#call`, and `DerivedRebuilder#call`.

- [ ] **Step 1: Write failing transport security/error specs**

Command specs inject a callable runner and assert arguments remain an array rather than a shell string:

```ruby
expect(runner).to receive(:call)
  .with({ "GH_HOST" => "github.com" }, "gh", "api", "repos/o/r", stdin_data: "")
  .and_return(["{}", "", instance_double(Process::Status, success?: true, exitstatus: 0)])

transport.capture("gh", "api", "repos/o/r", env: { "GH_HOST" => "github.com" })
```

HTTP specs use WebMock to prove JSON parsing, query encoding, 429 `Retry-After` classification, 401 authentication classification, malformed JSON handling, and redacted error messages.

Run both specs. Expected: FAIL with undefined transport constants.

- [ ] **Step 2: Implement shell-free command execution**

Use `Open3.capture3(env, *argv, stdin_data: "")`; never pass a single command string. Return parsed-independent `Result = Data.define(:stdout, :stderr, :exitstatus)`. Raise `CommandError` whose message contains executable/exit status and sanitized stderr, but no environment values.

- [ ] **Step 3: Implement read-only HTTP JSON transport**

`HttpJson` accepts `base_uri:`, `default_headers:`, `open_timeout: 10`, `read_timeout: 30`, `max_retries: 3`, and injectable `sleeper:`. It permits only GET/POST methods used by read-only GraphQL, parses JSON with string keys, and raises typed `AuthenticationError`, `RateLimitError`, `TransientError`, or `ResponseError`.

For 429/502/503/504, retry with `Retry-After` or deterministic test-injected exponential delays. Never log request headers or bodies. Return:

```ruby
Response = Data.define(:status, :headers, :body)
```

- [ ] **Step 4: Write failing offline replay specs**

Seed two `source_records` in reverse observation order. Register a fake normalizer with `version`, `reset!`, and `call`. Assert `Reprocessor#call` invokes `reset!`, replays in `[source_updated_at || observed_at, observed_at, id]` order, updates `normalizer_version`, and creates a succeeded `normalization_run`.

Inject a transport double that raises if called; pass it nowhere to `Reprocessor`. Add a failure example proving canonical rows present before replay remain after rollback and the failed `normalization_run` is recorded.

- [ ] **Step 5: Implement transactional replay and disposable-cache interface**

`Reprocessor` receives `registry:` only. Inside one transaction it calls each registered normalizer's `reset!`, iterates retained records in deterministic order, invokes the matching normalizer, stamps versions, and then calls `DerivedRebuilder#call`. On failure it rolls back canonical changes and records failure outside the transaction.

`DerivedRebuilder` receives a list of cache model classes and calls `delete_all` inside a transaction. It must not delete `source_records`, canonical entity/event tables, metric definitions, or source coverage.

- [ ] **Step 6: Run focused and full verification**

```bash
mise exec -- bundle exec rspec spec/devdash/transports spec/devdash/reprocessing
mise exec -- bundle exec rspec
```

Expected: all examples pass; the replay spec proves no transport object is constructed or called.

- [ ] **Step 7: Commit Task 4**

```bash
git add lib/devdash/transports lib/devdash/reprocessing spec/devdash/transports spec/devdash/reprocessing
git commit -m "Add deterministic transports and offline replay"
```

---

### Task 5: Slack identity and role collector

**Parallel wave A:** Run alongside Tasks 6 and 7 after Task 4. This task owns only the Slack paths listed below and must not edit shared migrations, `lib/devdash.rb`, or CLI files.

**Files:**
- Create: `lib/devdash/sources/slack/client.rb`
- Create: `lib/devdash/sources/slack/collector.rb`
- Create: `lib/devdash/sources/slack/user_normalizer.rb`
- Create: `spec/devdash/sources/slack/client_spec.rb`
- Create: `spec/devdash/sources/slack/collector_spec.rb`
- Create: `spec/devdash/sources/slack/user_normalizer_spec.rb`
- Create: `spec/fixtures/slack/users_page_1.json`
- Create: `spec/fixtures/slack/users_page_2.json`

**Interfaces:**
- Consumes: `HttpJson`, `Ingestion::Batch`, `Ingestion::SourceObservation`, and the Task 2 person/identity/role models.
- Produces: `Slack::Client#each_user`, `Slack::Collector#call`, and normalizer registration for `source: "slack", entity_type: "user"`.

- [ ] **Step 1: Create representative paginated fixtures**

The first fixture contains the owner, a peer, a bot, a guest, and `response_metadata.next_cursor`. The second contains a deactivated engineer and an engineer whose profile has a title but no email. Preserve realistic Slack fields such as `id`, `team_id`, `deleted`, `is_bot`, `is_restricted`, `is_ultra_restricted`, `updated`, and the complete `profile` object. Use invented names, IDs, and addresses.

- [ ] **Step 2: Write failing Slack client specs**

Stub two `users.list` responses and assert:

```ruby
users = client.each_user.to_a

expect(users.map { |user| user.fetch("id") }).to eq(%w[U001 U002 U003 U004 U005 U006])
expect(a_request(:get, "https://slack.com/api/users.list")
  .with(query: hash_including("limit" => "200"))).to have_been_made.once
expect(a_request(:get, "https://slack.com/api/users.list")
  .with(query: hash_including("cursor" => "page-two"))).to have_been_made.once
```

Also prove an HTTP 200 response with `{ "ok": false, "error": "invalid_auth" }` raises `AuthenticationError`, and that the client never requests conversations or message-history endpoints.

Run:

```bash
mise exec -- bundle exec rspec spec/devdash/sources/slack/client_spec.rb
```

Expected: FAIL with an undefined Slack client constant.

- [ ] **Step 3: Implement the narrow Slack client**

`Client` accepts `transport:` and `token:`. It calls only `/api/users.list` with `limit=200`, follows nonblank response cursors, validates Slack's body-level `ok`, and yields complete user hashes. Pass `Authorization: Bearer ...` only to the transport; no exception or log text may contain the token.

- [ ] **Step 4: Write failing collector and normalizer specs**

Assert one successful run:

- stores one immutable observation per returned user with `scope_key: "workspace"` and the complete user payload;
- records a global `full_snapshot` cursor and source coverage for Slack users;
- creates one provisional person plus one Slack source identity per stable Slack user ID;
- sets `active`, `human`, `guest`, and `bot` flags from Slack fields rather than title guesses;
- creates an effective-dated role assignment from the exact profile title;
- closes the previous role assignment and opens a new one when a later observation changes the title;
- creates no new source record or role assignment when the exact snapshot is collected twice.

The normalizer must retain a user with no email as unresolved-but-inspectable. It must not merge people merely because display names match.

- [ ] **Step 5: Implement collection and deterministic normalization**

Use these identities and timestamps:

```ruby
external_id = payload.fetch("id")
source_updated_at = Time.at(payload.fetch("updated")).utc
entity_key = "slack:user:#{external_id}"
```

`Collector#call` opens one `Ingestion::Batch` for `slack/workspace`, writes every user, completes coverage only after the last page, and leaves the previous successful cursor intact on failure. `UserNormalizer#reset!` deletes only Slack-derived identities, provisional people with no remaining identities, and Slack role assignments. Its version begins at `1`.

Normalize email with trim/downcase, retain display name and real name as evidence, and store the original title verbatim. Do not classify role/level beyond a neutral unknown value here; Task 8 owns title classification and person merging.

- [ ] **Step 6: Verify idempotency and privacy boundaries**

```bash
mise exec -- bundle exec rspec spec/devdash/sources/slack
mise exec -- bundle exec rspec
```

Expected: all examples pass, fixture collection is idempotent, and request history contains only `users.list`.

- [ ] **Step 7: Commit Task 5**

```bash
git add lib/devdash/sources/slack spec/devdash/sources/slack spec/fixtures/slack
git commit -m "Collect Slack identities and role evidence"
```

---

### Task 6: GitHub canonical schema and collector

**Parallel wave A:** Run alongside Tasks 5 and 7 after Task 4. This task owns migration `002` and GitHub paths; it must not edit shared bootstrap, CLI, identity, metric, or reporting files.

**Files:**
- Create: `db/migrate/002_create_github_domain.rb`
- Create: `lib/devdash/models/pull_request.rb`
- Create: `lib/devdash/models/pull_request_event.rb`
- Create: `lib/devdash/models/pull_request_review.rb`
- Create: `lib/devdash/models/pull_request_file.rb`
- Create: `lib/devdash/models/commit.rb`
- Create: `lib/devdash/models/commit_file.rb`
- Create: `lib/devdash/sources/github/client.rb`
- Create: `lib/devdash/sources/github/collector.rb`
- Create: `lib/devdash/sources/github/normalizer.rb`
- Create: `spec/devdash/sources/github/client_spec.rb`
- Create: `spec/devdash/sources/github/collector_spec.rb`
- Create: `spec/devdash/sources/github/normalizer_spec.rb`
- Create: `spec/fixtures/github/pull_search.json`
- Create: `spec/fixtures/github/open_pulls.json`
- Create: `spec/fixtures/github/pull.json`
- Create: `spec/fixtures/github/reviews.json`
- Create: `spec/fixtures/github/timeline.json`
- Create: `spec/fixtures/github/pull_files.json`
- Create: `spec/fixtures/github/commits.json`
- Create: `spec/fixtures/github/commit.json`

**Interfaces:**
- Consumes: repository scopes, `Command`, the ingestion contract, and Task 2 foundation models.
- Produces: typed GitHub canonical tables, `GitHub::Client`, `GitHub::Collector#call(repository_scope:, since:)`, and one registered GitHub normalizer.

- [ ] **Step 1: Write the GitHub migration and failing schema specs**

Create normalized tables with these keys and constraints:

- `pull_requests`: repository FK, number, node ID, author person FK nullable, author login, state, draft flag, base branch, head SHA, merge SHA, opened/closed/merged/source-updated timestamps, additions, deletions, changed-files count; unique `(repository_id, number)` and unique non-null node ID.
- `pull_request_events`: PR FK, stable external ID, kind, actor person FK/login nullable, subject person FK/login nullable, occurred-at, derivation; unique `(pull_request_id, stable_external_id)`. Review-request events store the requested reviewer as subject and the requester as actor.
- `pull_request_reviews`: PR FK, stable GitHub review ID, reviewer person FK nullable, reviewer login, state, submitted-at; unique GitHub review ID.
- `pull_request_files`: PR FK, path, status, additions, deletions, exclusion category nullable; unique `(pull_request_id, path)`.
- `commits`: repository FK, SHA, author/committer person FKs nullable, source login/email evidence, authored/committed timestamps, parent count, default-branch reachable flag, associated PR FK nullable; unique `(repository_id, sha)`.
- `commit_files`: commit FK, path, status, additions, deletions, exclusion category nullable; unique `(commit_id, path)`.

Add foreign keys and indexes for all person/time/repository query paths. Run the schema spec and observe its failure before migrating.

- [ ] **Step 2: Write failing shell-free client specs**

Inject a recording `Command` fake and specify exact argument arrays for:

```text
gh api -X GET --paginate --slurp search/issues -f q=repo:starburstlabs/crm-web is:pr updated:2026-09-01T00:00:00Z..2026-09-03T00:00:00Z -f per_page=100
gh api -X GET --paginate --slurp repos/starburstlabs/crm-web/pulls -f state=open -f per_page=100
gh api repos/starburstlabs/crm-web/pulls/42
gh api -X GET --paginate --slurp repos/starburstlabs/crm-web/pulls/42/reviews -f per_page=100
gh api -X GET --paginate --slurp repos/starburstlabs/crm-web/issues/42/timeline -H Accept: application/vnd.github+json -f per_page=100
gh api -X GET --paginate --slurp repos/starburstlabs/crm-web/pulls/42/files -f per_page=100
gh api -X GET --paginate --slurp repos/starburstlabs/crm-web/commits -f sha=main -f since=... -f per_page=100
gh api repos/starburstlabs/crm-web/commits/abc123
```

The spec must assert the final command is still an argv array, pagination output is decoded as a sequence of JSON pages, a nonzero exit raises a typed source error, and stderr is sanitized.

- [ ] **Step 3: Implement GitHub client pagination**

Expose methods `repository`, `updated_pull_numbers`, `open_pull_numbers`, `pull`, `reviews`, `timeline`, `pull_files`, `default_branch_commits`, and `commit_detail`. All methods return source-shaped hashes/arrays and make no database decisions. Parse `gh api --paginate` output robustly by requesting `--slurp`, which produces one JSON array of page payloads; flatten only endpoint page arrays, never nested domain arrays.

Discover changed pull requests through `search/issues` over a closed updated-at range, then fetch each candidate through the pull endpoint for complete typed fields. GitHub Search caps a query at 1,000 results: if `total_count > 900`, bisect the time range until every slice is below that threshold, stopping with a clear error if a one-second slice still exceeds it. This makes daily sync proportional to changes instead of repository history while keeping a safe backfill path.

- [ ] **Step 4: Create fixtures and write failing collector specs**

Fixtures must include:

- an open PR older than the overlap window;
- a merged default-branch PR and a merged stacked/intermediate-branch PR;
- repeated review data reachable from more than one fetched page;
- review-requested, ready-for-review, closed, reopened, and merged timeline events;
- generated, vendored, lockfile, and ordinary files;
- a normal commit and a merge commit;
- the same SHA in fixtures for two configured repositories.

Assert that collection unions changed PR numbers with every open PR regardless of age, fetches each candidate PR once, refreshes children for changed/open PRs, adaptively splits an overfull search interval, walks default-branch commits since the requested boundary, writes repository-qualified cursors/coverage independently, and commits one repository even if another repository in an `all` expansion fails later.

- [ ] **Step 5: Implement repository-isolated collection**

Expand `RepositoryScope` into repositories, then open a separate ingestion batch and transaction per repository. On incremental runs use a configurable overlap (default 48 hours) from the last successful repository/entity cursor and query updated PR numbers over that bounded interval. Union those candidates with the API's complete open-PR list, including open PRs not yet known locally. Fetch the repository endpoint first to refresh default branch and archive state.

Every returned object becomes an immutable observation before normalization. Use stable entity keys such as:

```ruby
"github:#{full_name}:pull:#{number}"
"github:#{full_name}:review:#{review_id}"
"github:#{full_name}:pull_event:#{event_id}"
"github:#{full_name}:commit:#{sha}"
```

For current snapshots whose source has no stable event ID, include the parent key and canonical payload hash in the observation identity rather than a collection timestamp.

- [ ] **Step 6: Write failing normalizer specs**

Assert that normalization:

- upserts PRs and commits by repository-qualified stable keys;
- stores final PR file rows separately from commit-file rows;
- deduplicates a review solely by stable review ID, not comments or pages;
- records unresolved logins without inventing people matches;
- marks default-branch reachability based on the branch walk observation;
- retains intermediate-base PRs but leaves their exclusion to metric predicates;
- classifies excluded paths deterministically from configured globs and defaults;
- produces the same canonical rows when source observations replay in deterministic order.

- [ ] **Step 7: Implement the GitHub normalizer**

Use typed columns for every report input. Replace each parent snapshot's child-file set transactionally so removed/renamed files do not survive a newer final diff. Event/review rows are append/upsert operations by stable ID. Create provisional GitHub source identities/people for unresolved logins, without display-name matching. `reset!` deletes GitHub canonical children before parents, then GitHub identities and now-unreferenced provisional people; it never deletes repositories, cross-source people, or evidence. Begin at normalizer version `1`.

- [ ] **Step 8: Verify collector boundaries and idempotency**

```bash
mise exec -- bundle exec rspec spec/devdash/sources/github
mise exec -- bundle exec rspec
```

Expected: all examples pass; a repeated collection produces no duplicate canonical facts; identical SHAs in different repositories remain distinct.

- [ ] **Step 9: Commit Task 6**

```bash
git add db/migrate/002_create_github_domain.rb lib/devdash/models/pull_request.rb lib/devdash/models/pull_request_event.rb lib/devdash/models/pull_request_review.rb lib/devdash/models/pull_request_file.rb lib/devdash/models/commit.rb lib/devdash/models/commit_file.rb lib/devdash/sources/github spec/devdash/sources/github spec/fixtures/github
git commit -m "Collect normalized GitHub delivery evidence"
```

---

### Task 7: Linear canonical schema and collector

**Parallel wave A:** Run alongside Tasks 5 and 6 after Task 4. This task owns migration `003` and Linear paths; it must not edit shared bootstrap, CLI, identity, metric, or reporting files.

**Files:**
- Create: `db/migrate/003_create_linear_domain.rb`
- Create: `lib/devdash/models/linear_issue.rb`
- Create: `lib/devdash/models/linear_issue_event.rb`
- Create: `lib/devdash/models/issue_repository_link.rb`
- Create: `lib/devdash/sources/linear/client.rb`
- Create: `lib/devdash/sources/linear/collector.rb`
- Create: `lib/devdash/sources/linear/normalizer.rb`
- Create: `spec/devdash/sources/linear/client_spec.rb`
- Create: `spec/devdash/sources/linear/collector_spec.rb`
- Create: `spec/devdash/sources/linear/normalizer_spec.rb`
- Create: `spec/fixtures/linear/issues_page_1.json`
- Create: `spec/fixtures/linear/issues_page_2.json`
- Create: `spec/fixtures/linear/issue_history.json`

**Interfaces:**
- Consumes: `HttpJson`, the ingestion contract, and Task 2 foundation models.
- Produces: typed Linear canonical tables, `Linear::Client`, `Linear::Collector#call(since:)`, and normalizer registration for Linear issue snapshots/history.

- [ ] **Step 1: Write the Linear migration and failing schema specs**

Create:

- `linear_issues`: unique Linear ID, identifier, title, team/project/state IDs and names, state type, creator and current-assignee person FKs nullable plus source identity strings, estimate, created/started/completed/canceled/source-updated timestamps, URL, active flag.
- `linear_issue_events`: issue FK, stable external ID, kind, actor person FK nullable, from/to values, occurred-at, `derivation` (`source_event` or `observed_diff`); unique `(linear_issue_id, stable_external_id)`.
- `issue_repository_links`: issue FK, repository FK nullable, evidence kind, evidence reference, confidence, primary flag, resolution status; unique on the complete evidence identity and a partial unique index allowing at most one primary repository per issue.

Index creator, assignee, state type, relevant timestamps, repository, and resolution status.

- [ ] **Step 2: Create fixtures and write failing GraphQL client specs**

Use paginated official GraphQL-shaped fixtures with `pageInfo.hasNextPage/endCursor`. Include issue nodes with team, project, labels, creator, assignee, state, attachments, and history nodes. The query must request every field later preserved/normalized, but no comments or descriptions.

Assert `Client#each_issue(updated_since:)` POSTs to `/graphql`, passes variables rather than interpolating them into query text, follows cursors, and raises when the response has top-level `errors` even with HTTP 200. Assert `Client#issue_history(id:)` paginates its connection independently.

- [ ] **Step 3: Implement the read-only Linear client**

Use `HttpJson#post` with `Authorization: <LINEAR_API_KEY>` and JSON variables. Keep GraphQL documents as frozen constants. Return full node hashes to the collector. Error messages may include GraphQL error codes/messages but must omit headers, variables containing identity values, and response payloads.

- [ ] **Step 4: Write failing collector and observed-transition specs**

Specify that the collector:

- incrementally queries by `updatedAt` with a 48-hour overlap;
- explicitly refreshes every locally active issue even when old;
- saves complete issue/history observations before canonical writes;
- uses one global Linear batch but records issue and history coverage separately;
- advances cursors only after successful normalization;
- rolls back the batch while preserving the prior cursor on a later-page failure.

Create two issue snapshots where state or assignee changes without a source history event. Assert a deterministic `observed_diff` event is derived from consecutive source observations, has a nullable actor, and is not described as an authored transition.

- [ ] **Step 5: Implement Linear collection and normalization**

Use the Linear UUID as the stable issue key and history UUID where available. For an observed diff, derive a stable ID from issue ID, field, previous payload hash, current payload hash, and effective source timestamp. Upsert typed issue snapshots, source identities for creator/assignee/known event actors, and normalized history events.

`Normalizer#reset!` deletes Linear issue links/events/issues and Linear-only provisional identities/people while retaining shared people and evidence. Begin at version `1`. Repository link inference itself belongs to Task 8; the normalizer may persist explicit GitHub attachment/URL evidence as unresolved `issue_repository_links` without choosing a repository.

- [ ] **Step 6: Verify replay and idempotency**

```bash
mise exec -- bundle exec rspec spec/devdash/sources/linear
mise exec -- bundle exec rspec
```

Expected: all examples pass; repeated snapshots/events deduplicate; source-absent transition actors remain null and visibly derived.

- [ ] **Step 7: Commit Task 7**

```bash
git add db/migrate/003_create_linear_domain.rb lib/devdash/models/linear_issue.rb lib/devdash/models/linear_issue_event.rb lib/devdash/models/issue_repository_link.rb lib/devdash/sources/linear spec/devdash/sources/linear spec/fixtures/linear
git commit -m "Collect normalized Linear issue evidence"
```

---

### Task 8: Cross-source identity, cohort, and issue-repository resolution

**Merge gate:** Integrate and verify Tasks 5–7 before starting. Resolve migration ordering without renumbering `002` or `003`, then run the entire suite.

**Files:**
- Create: `config/people.example.yml`
- Create: `lib/devdash/identity/manual_configuration.rb`
- Create: `lib/devdash/identity/person_merger.rb`
- Create: `lib/devdash/identity/resolver.rb`
- Create: `lib/devdash/identity/role_normalizer.rb`
- Create: `lib/devdash/identity/cohort_resolver.rb`
- Create: `lib/devdash/identity/issue_repository_resolver.rb`
- Create: `spec/devdash/identity/manual_configuration_spec.rb`
- Create: `spec/devdash/identity/person_merger_spec.rb`
- Create: `spec/devdash/identity/resolver_spec.rb`
- Create: `spec/devdash/identity/role_normalizer_spec.rb`
- Create: `spec/devdash/identity/cohort_resolver_spec.rb`
- Create: `spec/devdash/identity/issue_repository_resolver_spec.rb`

**Interfaces:**
- Consumes: all source identities, Slack titles, configured repositories, GitHub PR links, and Linear mapping evidence.
- Produces: `Identity::Resolver#call`, `RoleNormalizer#call`, `CohortResolver#call(owner:, at:, repository_scope:)`, and `IssueRepositoryResolver#call`.

- [ ] **Step 1: Define and test authoritative local overrides**

Use this documented shape in `config/people.example.yml`:

```yaml
owner: john
people:
  john:
    identities:
      github: jrose-wealthbox
      slack: U001
      linear: 11111111-1111-1111-1111-111111111111
    role: software_engineer
    level: senior
  excluded-contractor:
    exclude_from_cohort: true
role_rules:
  - pattern: '(?i)senior.*(software|full.stack|rails).*engineer'
    role: software_engineer
    level: senior
repository_mappings:
  linear_projects:
    CRM: crm-web
  linear_labels:
    repo:repo1: repo1
```

Specs reject unknown sources, duplicate external identities, unknown repository selectors, invalid regular expressions, missing owner, and overlapping contradictory manual mappings. No secrets or emails are required in this file.

- [ ] **Step 2: Write failing identity-resolution and merge-audit specs**

Test evidence priority: manual identity mapping first, then exact normalized verified email, otherwise unresolved. A display-name match alone must stay unresolved. Assert person merging updates every person FK transactionally, retains the destination person, removes no source observations, and creates a merge-audit row with source/destination, reason, and evidence/config reference.

Test a collision where one email points to two explicitly mapped people; resolver must report ambiguity rather than merge either person.

- [ ] **Step 3: Implement deterministic identity resolution**

`ManualConfiguration` loads with `YAML.safe_load_file`. `Resolver#call` returns a result object containing merged, unresolved, and ambiguous counts. `PersonMerger` enumerates all canonical FK columns explicitly—do not discover them from arbitrary schema names—and performs updates plus audit insertion in one transaction. It retains the source person as inactive with `merged_into_id` set, so the merge-audit foreign key and reversal evidence remain valid.

Re-running the same override must be a no-op. Incorrect mappings remain repairable because source identities and source records are not deleted.

- [ ] **Step 4: Write failing role-normalization specs**

Cover configured overrides, ordered regex rules, default built-in title patterns, unknown titles, effective-date boundaries, and Slack title changes. Rules produce normalized `role` and `level` separately. Preserve the original title and rule identifier in the assignment; never infer level from GitHub activity.

- [ ] **Step 5: Implement effective-dated role classification**

Manual person role/level wins, then configured title rules in file order, then conservative built-ins. Built-ins recognize software engineering titles and common levels but return `unknown` for managers, product/design roles, interns, contractors, or ambiguous titles unless configured. Close/open assignments only when the effective normalized classification changes.

- [ ] **Step 6: Write failing cohort specs for single and all scopes**

Given an owner who is a senior software engineer, assert the cohort includes only active human people with the same role/level at the report end. Exclude the owner, bots, guests, deactivated, merged source people, unresolved, explicit exclusions, and role mismatches.

For a single repository, require canonical GitHub activity in that repository during trailing 180 days. For `all`, use the union of people active in at least one configured repository. Return both included IDs and inspectable exclusion reasons.

- [ ] **Step 7: Implement cohort resolution**

Use report `end_at` for role effectiveness and `[end_at - 180 days, end_at)` for repository activity. Activity eligibility may use authored PRs, commits, or submitted reviews; it is only a cohort-presence rule and never a performance metric.

- [ ] **Step 8: Write failing issue-repository resolution specs**

Specify priority:

1. linked GitHub PR in a configured repository;
2. configured Linear project/team/label mapping;
3. identifier/title token such as `[crm-web]`, if enabled by configuration;
4. unresolved.

Assert multiple equally strong repositories yield `multi-repo`, one explicit primary override wins, and no configured evidence yields `unmapped`. A single-repository scope includes only primary links in its main metric. An `all` scope includes each issue once and retains `multi-repo`/`unmapped` buckets.

- [ ] **Step 9: Implement repository linking with evidence preservation**

Never discard lower-priority evidence rows. Mark exactly one resolved link primary only when the result is unambiguous or manually overridden; otherwise store all candidates with resolution status. Re-running resolution replaces only derived resolution fields and remains deterministic.

- [ ] **Step 10: Run the merge-gate verification**

```bash
mise exec -- bundle exec rspec spec/devdash/identity
mise exec -- bundle exec rspec
```

Expected: all examples pass; source fixtures from all three systems resolve into an inspectable cohort while ambiguities remain visible.

- [ ] **Step 11: Commit Task 8**

```bash
git add config/people.example.yml lib/devdash/identity spec/devdash/identity
git commit -m "Resolve identities cohorts and repository links"
```

---

### Task 9: Versioned metric registry, windows, comparisons, and caches

**Sequential interface gate:** Start only after Task 8. This task freezes the query/result contract consumed independently by Tasks 10 and 11.

**Files:**
- Create: `db/migrate/004_create_metric_metadata_and_report_cache.rb`
- Create: `lib/devdash/models/metric_definition.rb`
- Create: `lib/devdash/models/metric_framework_mapping.rb`
- Create: `lib/devdash/models/report_snapshot.rb`
- Create: `lib/devdash/metrics/window.rb`
- Create: `lib/devdash/metrics/weekday_normalizer.rb`
- Create: `lib/devdash/metrics/definition.rb`
- Create: `lib/devdash/metrics/result.rb`
- Create: `lib/devdash/metrics/registry.rb`
- Create: `lib/devdash/metrics/statistics.rb`
- Create: `lib/devdash/metrics/comparison.rb`
- Create: `lib/devdash/metrics/coverage.rb`
- Create: `lib/devdash/metrics/report_cache.rb`
- Create: `spec/devdash/metrics/window_spec.rb`
- Create: `spec/devdash/metrics/weekday_normalizer_spec.rb`
- Create: `spec/devdash/metrics/registry_spec.rb`
- Create: `spec/devdash/metrics/statistics_spec.rb`
- Create: `spec/devdash/metrics/comparison_spec.rb`
- Create: `spec/devdash/metrics/coverage_spec.rb`
- Create: `spec/devdash/metrics/report_cache_spec.rb`

**Interfaces:**
- Consumes: canonical models, cohort resolver, repository scope, and source coverage.
- Produces: immutable metric definitions/results, weekday-normalized count context, comparison statistics, coverage state, and semantically keyed disposable snapshots.

- [ ] **Step 1: Write the metric metadata/cache migration and failing model specs**

Create:

- `metric_definitions`: unique `(key, version)`, name, description, unit, value type, signal role, measurement scope, collection mode, directionality, EngThrive section, active flag.
- `metric_framework_mappings`: metric-definition FK, framework, dimension, status; unique `(metric_definition_id, framework, dimension)`.
- `report_snapshots`: unique cache key, window start/end, repository-scope hash, cohort hash, metric-versions hash, source-watermark hash, format version, structured JSON, rendered text, created-at.

Constrain enum-like strings in models and validate that service-scoped DORA definitions cannot have person-comparison mode. `report_snapshots` must have no foreign key from canonical tables.

- [ ] **Step 2: Write failing half-open-window specs**

`Metrics::Window.for("7d", end_at:)` creates a current and exactly adjacent previous interval. Support only `7d`, `30d`, and `180d` in V1. Verify an event exactly at `start_at` is included, one exactly at `end_at` is excluded, and UTC conversion is explicit.

Expose:

```ruby
Window = Data.define(:key, :start_at, :end_at) do
  def previous
    self.class.new(key:, start_at: start_at - duration, end_at: start_at)
  end
end
```

Use exact second durations for rolling windows, not calendar-month subtraction.

- [ ] **Step 3: Write failing registry and definition specs**

Before the registry specs, add `WeekdayNormalizer` examples for windows beginning/ending mid-day, spanning weekends, and spanning 7/30/180 days. It returns the sum of weekday overlap seconds divided by 86,400 using UTC boundaries. This is explicitly an approximate weekday-equivalent denominator until Calendar/work-schedule data exists; return `nil` only for an empty interval.

A query object registers one immutable `Definition` containing:

```ruby
Definition = Data.define(
  :key, :version, :name, :description, :unit, :value_type,
  :signal_role, :measurement_scope, :collection_mode,
  :directionality, :engthrive_section, :framework_mappings,
  :required_coverage
)
```

Require unique keys, positive integer versions, explicit units, one of `outcome/diagnostic/activity/guardrail`, and declared SPACE/DevEx mappings where applicable. Registry lookup returns the query class/factory and definition; registration order must not determine report order.

- [ ] **Step 4: Implement windows, weekday normalization, and the metric registry**

Implement `WeekdayNormalizer` by intersecting the window with each UTC date and summing only Monday–Friday overlap seconds. Persist or update definition metadata from code during application boot, but keep formulas in Ruby/SQL query objects. A definition-version change creates a distinct database definition; it does not mutate historical cached semantic identity. The registry exposes `fetch(key)` and `active_definitions` sorted by EngThrive section plus configured display order.

- [ ] **Step 5: Write failing result and comparison specs**

Use one result per person, metric, window, and exact repository scope:

```ruby
Result = Data.define(
  :definition, :person_id, :window, :repository_scope,
  :value, :sample_count, :breakdown, :coverage
)
```

For a count metric, include every eligible peer and use zero for no matching facts. For a duration metric, exclude peers with no completed observations and report the smaller `n`. Calculate median, p25, p75, IQR, owner percentile rank, and owner-vs-median difference. When `n < 3`, return `insufficient_peer_sample: true` and no percentile.

Directionless metrics (`commits`, changed lines, meeting load, AI spend) may show distributions but must return no favorable/unfavorable interpretation. Do not create a composite score or rank ordering of named people.

- [ ] **Step 6: Implement stable statistics and comparisons**

Document and test one quantile convention, including odd/even collections and duplicate values. `Comparison#call` must first aggregate each person's facts across the exact repository set, then calculate the peer distribution. It must never pool raw events across people or average repository-level percentiles.

For current-versus-previous output, return absolute delta for counts and durations plus percent delta only when the previous value is nonzero. Preserve `nil` as unavailable; never coerce missing duration observations to zero. Count results also expose `value / WeekdayNormalizer.equivalent_days(window)` as neutral activity-rate context; duration results expose median and p75 from their per-observation samples.

- [ ] **Step 7: Write failing source-coverage specs**

For each definition, declare required `(source, entity_type)` coverage. Assert:

- one missing repository/entity makes an `all` metric partial but identifies only the affected repository;
- a global Linear or Slack requirement is evaluated once rather than per repository;
- a window extending before achieved coverage is partial;
- stale data is distinguishable from absent historical coverage;
- missing coverage never silently changes a numeric value into zero.

- [ ] **Step 8: Implement coverage evaluation and semantic report caching**

`Coverage#call` returns `complete`, `partial`, or `unavailable`, reasons, affected repositories, and last-success timestamps. Calculate a source-watermark hash from the exact relevant successful coverage/cursor rows.

`ReportCache` hashes canonical JSON containing window boundaries, scope configuration hash, cohort-definition hash, sorted metric key/versions, source-watermark hash, and format version. A changed observation watermark or metric version must miss the cache. `clear!` may delete every snapshot without touching other tables.

- [ ] **Step 9: Run the interface-gate verification**

```bash
mise exec -- bundle exec rspec spec/devdash/metrics
mise exec -- bundle exec rspec
```

Expected: all examples pass, including hand-calculated distribution assertions and cache invalidation.

- [ ] **Step 10: Commit Task 9**

```bash
git add db/migrate/004_create_metric_metadata_and_report_cache.rb lib/devdash/models/metric_definition.rb lib/devdash/models/metric_framework_mapping.rb lib/devdash/models/report_snapshot.rb lib/devdash/metrics spec/devdash/metrics
git commit -m "Add versioned metric and comparison core"
```

---

### Task 10: GitHub delivery and review metrics

**Parallel wave B:** Run alongside Task 11 after Task 9. This task owns only `metrics/github` paths and corresponding specs; it must not edit the registry core, CLI, or reporting files.

**Files:**
- Create: `lib/devdash/metrics/github/merged_pull_requests.rb`
- Create: `lib/devdash/metrics/github/pr_ship_time.rb`
- Create: `lib/devdash/metrics/github/authored_commits.rb`
- Create: `lib/devdash/metrics/github/lines_shipped.rb`
- Create: `lib/devdash/metrics/github/direct_push_lines.rb`
- Create: `lib/devdash/metrics/github/unique_pull_requests_reviewed.rb`
- Create: `lib/devdash/metrics/github/reviews_submitted.rb`
- Create: `lib/devdash/metrics/github/review_breadth.rb`
- Create: `lib/devdash/metrics/github/review_pickup_time.rb`
- Create: `lib/devdash/metrics/github/register.rb`
- Create: `spec/devdash/metrics/github/delivery_metrics_spec.rb`
- Create: `spec/devdash/metrics/github/review_metrics_spec.rb`

**Interfaces:**
- Consumes: the Task 9 metric contract and normalized GitHub tables only.
- Produces: nine registered, versioned GitHub metric query objects with per-repository and aggregate breakdowns.

- [ ] **Step 1: Build a hand-calculated GitHub metric fixture in specs**

Create records directly through canonical models for two people and two repositories. Include a default-branch PR, stacked/intermediate PR, unmerged PR, generated and ordinary file stats, normal and merge commits, a direct-push commit, duplicate-looking review/comment activity with one stable review ID, and PRs with/without review-request events.

Expected figures must be literal hand calculations in the spec; do not derive expected values through production helpers.

- [ ] **Step 2: Write failing delivery-metric specs**

Specify these V1 definitions:

- `github.merged_pull_requests.v1`: count authored PRs whose `merged_at` is in-window and base branch equals repository default branch.
- `github.pr_ship_time_hours.v1`: median elapsed hours from opened-at to merged-at for those PRs, with per-PR sample count.
- `github.authored_commits.v1`: distinct non-merge commits authored by the person, default-branch reachable, committed in-window; activity/directionless.
- `github.lines_shipped.v1`: additions plus deletions from final file diffs of qualifying merged PRs; primary value excludes classified generated/vendor/lock/configured paths and breakdown reports included/excluded additions/deletions.
- `github.direct_push_lines.v1`: file additions plus deletions from reachable, non-merge commits not associated with a PR; diagnostic/directionless and visibly separate from lines shipped.

Assert repository breakdown keys use full repository identity, while the `all` value aggregates a person's repository results once.

- [ ] **Step 3: Implement GitHub delivery queries against typed columns**

Each class exposes `definition` and `call(person:, window:, repository_scope:)`. Share small private scopes only where their SQL predicates are identical; do not create a generic activity query language. No query may access `SourceRecord#payload_json`.

For ship-time duration, select PRs by `merged_at` window but measure `merged_at - opened_at` even when opening predates the window. Store/display hours with sufficient precision for aggregation and round only in the renderer.

- [ ] **Step 4: Write failing review-metric specs**

Specify:

- `github.unique_prs_reviewed.v1`: distinct non-self PRs with a submitted review by the person in-window.
- `github.reviews_submitted.v1`: distinct stable review IDs in-window with approval/comment/changes-requested breakdown.
- `github.review_breadth.v1`: distinct PR authors helped by submitted reviews, excluding self-review, with a distinct repositories-reviewed breakdown.
- `github.review_pickup_time_hours.v1`: median time from the first review-request event addressed to the reviewer until that reviewer's first subsequent submitted review; exclude PRs lacking a request for that reviewer and report sample count.

Assert repeat review submissions on one PR count as multiple reviews but one reviewed PR; line comments and pending reviews are not submitted reviews. Exclude self reviews and bot reviewers from every review metric. Verify unresolved reviewer identity is excluded and surfaced through coverage/diagnostics rather than assigned by login guess.

- [ ] **Step 5: Implement review queries and registration**

Use stable review IDs and typed event timestamps. Register framework mappings: EngThrive Speed/Ease diagnostics as appropriate; SPACE communication/collaboration and performance; DevEx feedback-loop coverage for pickup time. Activity-only review counts remain directionless.

`register.rb` exposes one `call(registry)` method so Task 12 can wire all GitHub definitions without editing Task 9 files.

- [ ] **Step 6: Verify repository aggregation and SQL independence from raw JSON**

```bash
mise exec -- bundle exec rspec spec/devdash/metrics/github
rg -n "SourceRecord|payload_json|source_records" lib/devdash/metrics/github
mise exec -- bundle exec rspec
```

Expected: metrics pass and `rg` returns no matches in GitHub metric implementations.

- [ ] **Step 7: Commit Task 10**

```bash
git add lib/devdash/metrics/github spec/devdash/metrics/github
git commit -m "Add GitHub delivery and review metrics"
```

---

### Task 11: Linear creation, completion, and flow metrics

**Parallel wave B:** Run alongside Task 10 after Task 9. This task owns only `metrics/linear` paths and corresponding specs; it must not edit the registry core, CLI, or reporting files.

**Files:**
- Create: `lib/devdash/metrics/linear/tickets_created.rb`
- Create: `lib/devdash/metrics/linear/completed_while_assigned.rb`
- Create: `lib/devdash/metrics/linear/queue_time.rb`
- Create: `lib/devdash/metrics/linear/active_cycle_time.rb`
- Create: `lib/devdash/metrics/linear/end_to_end_time.rb`
- Create: `lib/devdash/metrics/linear/reopened_tickets.rb`
- Create: `lib/devdash/metrics/linear/register.rb`
- Create: `spec/devdash/metrics/linear/ticket_metrics_spec.rb`
- Create: `spec/devdash/metrics/linear/flow_metrics_spec.rb`

**Interfaces:**
- Consumes: the Task 9 metric contract plus normalized Linear issues/events/repository links only.
- Produces: six registered, versioned Linear metric query objects with primary/multi-repo/unmapped breakdowns.

- [ ] **Step 1: Build a hand-calculated Linear fixture in specs**

Create canonical issues covering: creator differs from completing assignee, reassignment before completion, completion with no assignee, queue-to-start timestamps, reopen and second completion, canceled issue, primary repository link, ambiguous multi-repo links, and unmapped issue. Include both source-authored and observed-diff events with nullable actors.

- [ ] **Step 2: Write failing attribution/count specs**

Specify:

- `linear.tickets_created.v1`: issues whose creator is the person and `created_at` is in-window.
- `linear.completed_while_assigned.v1`: terminal completed transitions in-window where the person was assignee at that transition; label exactly “completed while assigned,” not “tickets closed by.” Count an issue once per qualifying terminal completion period and separately show reopened/recompleted cases.
- `linear.reopened_tickets.v1`: issues assigned to the person at an in-window reopen transition; diagnostic, not a negative score.

Assert current assignee snapshots do not retroactively replace transition-time assignment. Unknown actor/assignee facts stay unknown.

- [ ] **Step 3: Implement attribution/count queries**

Reconstruct assignment-at-transition from ordered canonical events plus issue initial/snapshot facts. Encapsulate that temporal logic in a private helper under `metrics/linear`, with tests for equal timestamps using stable event ID as a deterministic tiebreaker.

Repository grouping uses resolved `issue_repository_links`. Single-repository main values include only that repository's primary issues. `all` counts every issue once and adds `multi-repo` and `unmapped` breakdown buckets.

- [ ] **Step 4: Write failing flow-duration specs**

Specify:

- `linear.queue_time_hours.v1`: created-at to first started-at.
- `linear.active_cycle_time_hours.v1`: first started-at to qualifying completion, subtracting explicit reopened/non-started intervals only when events provide the necessary boundaries; otherwise use documented elapsed approximation and flag it in breakdown.
- `linear.end_to_end_time_hours.v1`: created-at to qualifying completion.

Select samples by qualifying completion in-window for cycle/end-to-end metrics. Queue-time samples enter when first started-at is in-window. Exclude missing boundaries from numeric distributions and return excluded counts/reasons.

- [ ] **Step 5: Implement duration queries and framework mappings**

Use UTC timestamp arithmetic at full precision. Register these as EngThrive Speed diagnostics and SPACE performance; map queue/cycle to DevEx flow-state proxy only as system telemetry, explicitly not proof of cognitive flow. Definitions state the approximation and attribution rule.

`register.rb` exposes one `call(registry)` method for Task 12.

- [ ] **Step 6: Verify issue-once aggregation and typed-column use**

```bash
mise exec -- bundle exec rspec spec/devdash/metrics/linear
rg -n "SourceRecord|payload_json|source_records" lib/devdash/metrics/linear
mise exec -- bundle exec rspec
```

Expected: metrics pass, an `all` report never duplicates a multi-linked issue, and `rg` returns no raw-evidence query references.

- [ ] **Step 7: Commit Task 11**

```bash
git add lib/devdash/metrics/linear spec/devdash/metrics/linear
git commit -m "Add Linear attribution and flow metrics"
```

---

### Task 12: Report assembly, terminal renderer, and CLI commands

**Merge gate:** Integrate and verify Tasks 10–11 first. This task owns shared registration, orchestration, and presentation.

**Files:**
- Modify: `lib/devdash.rb`
- Modify: `bin/devdash`
- Create: `lib/devdash/reporting/report.rb`
- Create: `lib/devdash/reporting/report_builder.rb`
- Create: `lib/devdash/reporting/terminal_renderer.rb`
- Create: `lib/devdash/reporting/framework_coverage.rb`
- Create: `lib/devdash/commands/base.rb`
- Create: `lib/devdash/commands/sync.rb`
- Create: `lib/devdash/commands/backfill.rb`
- Create: `lib/devdash/commands/report.rb`
- Create: `lib/devdash/commands/reprocess.rb`
- Create: `lib/devdash/commands/rebuild_derived.rb`
- Create: `lib/devdash/cli.rb`
- Create: `spec/devdash/reporting/report_builder_spec.rb`
- Create: `spec/devdash/reporting/terminal_renderer_spec.rb`
- Create: `spec/devdash/commands/report_spec.rb`
- Create: `spec/devdash/commands/offline_commands_spec.rb`
- Create: `spec/fixtures/reports/default_7d.txt`
- Create: `spec/fixtures/reports/all_30d.txt`

**Interfaces:**
- Consumes: all collectors, identity/cohort resolvers, metric registrations, comparisons, coverage, and cache.
- Produces: `Devdash::CLI.start(argv, out:, err:)` and working `sync`, `backfill`, `report`, `reprocess`, and `rebuild-derived` commands.

- [ ] **Step 1: Wire application loading without source side effects**

Update `lib/devdash.rb` to require all production components in dependency order, then construct dependencies only inside command execution. Requiring the library must not open the database, read credentials, run migrations, invoke `gh`, or perform HTTP requests.

Create one registry-builder method that invokes `Metrics::GitHub::Register.call(registry)` and `Metrics::Linear::Register.call(registry)`. Assert every registered definition validates and persists metadata after database connection.

- [ ] **Step 2: Write failing structured-report assembly specs**

`ReportBuilder#call(owner:, window:, repository_scope:)` must return a structured `Reporting::Report` containing:

- owner, report timestamp, current and previous windows;
- resolved repository scope and cohort sample description;
- EngThrive sections in Speed, Ease, Quality, Thriving order;
- for each metric: signal role, current owner result, previous result, delta, per-repository breakdown, peer distribution/sample size where allowed, and coverage;
- source freshness and partial-data reasons;
- framework coverage statuses for SPACE, DevEx, and DORA.

Use fake metric query objects with exact values first. Assert the builder never computes a composite score, never marks a directionless metric favorable/unfavorable, and never creates individual DORA comparisons.

- [ ] **Step 3: Implement report assembly and cache use**

Build the cohort once for the exact report end/scope. Evaluate owner and every eligible peer through the same definition/window/scope. For `all`, preserve aggregate and per-repository breakdowns from query results. Apply comparisons only after person-level aggregation.

Read a report snapshot only when its complete semantic cache key matches. Store structured JSON and rendered text after successful assembly/render. An uncached report still uses only SQLite.

- [ ] **Step 4: Write failing terminal golden-output specs**

Create sanitized deterministic golden files covering default `crm-web` 7-day output and `all` 30-day output. Freeze the clock and use invented people. The terminal format must visibly include:

```text
Personal Engineering Dashboard · 7d · crm-web
Current: 2026-08-27 00:00Z → 2026-09-03 00:00Z
Previous: 2026-08-20 00:00Z → 2026-08-27 00:00Z

SPEED
Metric                         Role        You   Previous   Delta   Peers
Merged PRs                     outcome       4          3      +1   median 3 · n=5
PR ship time                   diagnostic  19h        24h      -5h  median 21h · n=4
```

The complete golden output also includes Ease, Quality, Thriving guardrail status, repository breakdowns, current/previous comparisons, count values per weekday-equivalent, duration median/p75, peer median/IQR, peer sample warnings, coverage/freshness, and SPACE/DevEx/DORA coverage. Activity rows use neutral language. When `n < 3`, print `insufficient peer sample (n=N)`.

- [ ] **Step 5: Implement stable terminal rendering**

Use plain text and standard-library formatting; avoid ANSI color in golden files. Round display values only at render time. Keep units explicit, show `—` for unavailable, distinguish `0` from unavailable, and label partial figures inline. For `all`, print `All configured repos (N)` plus one breakdown block per repository and explicit `multi-repo`/`unmapped` Linear buckets.

Framework coverage behavior:

- SPACE dimensions render `measured`, `partial`, or `unavailable` from registered mappings and actual coverage.
- DevEx dimensions render the same statuses and label telemetry proxies as proxies.
- DORA renders `unavailable in V1 (service-level source not configured)` and never appears in the peer table.
- Thriving renders `unavailable until private self-report is configured`; telemetry is not substituted.

- [ ] **Step 6: Write failing CLI parsing and offline-command specs**

Specify:

```text
devdash sync [github|linear|slack|all] [--repo SCOPE]
devdash backfill --days N [--repo SCOPE]
devdash report --window 7d|30d|180d [--repo SCOPE] [--at ISO8601]
devdash reprocess
devdash rebuild-derived
```

Omitted report repository resolves to the configured default. Accept alias, full `owner/name`, and `all`. Reject `--repo` on a Slack-only or Linear-only sync with a clear usage error; `sync all --repo repo1` limits GitHub only while global sources remain global. Reject invalid windows, nonpositive backfill days, unknown sources, and extra arguments with exit status `2`.

Inject fail-on-call GitHub/HTTP transports into `report`, `reprocess`, and `rebuild-derived`; assert each command succeeds without invoking them.

- [ ] **Step 7: Implement commands and executable exit contracts**

Use `OptionParser` per subcommand. Commands return integer exit codes; `bin/devdash` only invokes `Devdash::CLI.start(ARGV, out: $stdout, err: $stderr)` and exits with that value. Domain/configuration failures print a concise message to stderr with exit `1`; usage failures exit `2`; successful report output goes only to stdout.

`sync` runs identity/role/repository resolution after source collection. `backfill` requests at least the explicit number of days plus configured safety margin and records achieved coverage. `reprocess` invokes normalizers, identity resolution, repository resolution, and derived rebuild in deterministic order. `rebuild-derived` deletes only snapshots and recomputes on demand.

- [ ] **Step 8: Verify report fidelity and offline guarantees**

```bash
mise exec -- bundle exec rspec spec/devdash/reporting spec/devdash/commands
mise exec -- bin/devdash --help
mise exec -- bundle exec rspec
```

Expected: exact golden files pass, all repository selectors resolve, and offline commands construct/call no source transport.

- [ ] **Step 9: Commit Task 12**

```bash
git add lib/devdash.rb bin/devdash lib/devdash/reporting lib/devdash/commands lib/devdash/cli.rb spec/devdash/reporting spec/devdash/commands spec/fixtures/reports
git commit -m "Render private repository-scoped performance reports"
```

---

### Task 13: Sync orchestration, diagnostics, end-to-end acceptance, and documentation

**Sequential acceptance:** This is the final V1 task. It proves the architecture works as a whole and documents real setup without adding deferred Calendar, AI-spend, survey, CI, deployment, or incident collectors.

**Files:**
- Create: `lib/devdash/sync_runner.rb`
- Create: `lib/devdash/doctor.rb`
- Create: `lib/devdash/commands/doctor.rb`
- Modify: `lib/devdash/cli.rb`
- Modify: `config/devdash.example.yml`
- Create: `README.md`
- Create: `spec/devdash/sync_runner_spec.rb`
- Create: `spec/devdash/doctor_spec.rb`
- Create: `spec/devdash/end_to_end_spec.rb`
- Create: `spec/devdash/data_quality_spec.rb`

**Interfaces:**
- Consumes: the complete V1 application.
- Produces: independently observable multi-source sync, `devdash doctor`, documented local operation, and fixture-backed acceptance evidence.

- [ ] **Step 1: Write failing independent-sync orchestration specs**

Given scope `all`, assert `SyncRunner` expands GitHub into one run per enabled repository and executes global Linear/Slack runs independently. One repository failure must not roll back another repository or global source. Return a summary with succeeded/failed source scopes and exit nonzero only after all requested independent units have been attempted.

Verify default incremental overlap, explicit refresh of open PRs/active issues, source-specific cursor advancement, and first-run backfill of at least 360 days plus configured safety margin.

- [ ] **Step 2: Implement sync orchestration**

`SyncRunner` receives collector factories and an injectable clock. It catches failures at the source-scope boundary, never at individual-object granularity, and returns structured results. Avoid concurrent SQLite writes in V1; source scopes execute sequentially within the daily process even though implementation tasks were parallelized.

This is deliberate: once-daily runtime does not justify lock contention or a job system, while repository-scoped transactions already preserve partial success.

- [ ] **Step 3: Write failing doctor specs**

`Doctor#call` performs read-only checks and returns status/severity/remediation for:

- config validity, exactly one default, database path/file permissions, and current schema;
- presence of `gh`, `jq`, `rg`, and `ast-grep`, warning rather than crashing if a developer tool is missing;
- GitHub authentication/access to every configured repository;
- Linear and Slack token presence plus minimal API access;
- owner identity resolution, unresolved/ambiguous identities, title normalization, cohort size;
- unresolved/multi-repo Linear links;
- achieved coverage and last-success freshness per source/entity/repository;
- availability of 7/30/180-day reports.

Token values, emails, raw bodies, and Slack/Linear payloads must not appear in results. Use fake transports in specs.

- [ ] **Step 4: Implement doctor and CLI command**

`devdash doctor` may make narrow credential/access probes but never mutates GitHub, Linear, Slack, or canonical data. Add `--offline` to skip probes and inspect local state only. Return exit `0` when healthy, `1` for errors, and still print all checks. Missing `rg`, `jq`, or `ast-grep` is a warning for maintainers, not a dashboard-runtime failure; missing `gh` is an error because V1 GitHub collection requires it.

- [ ] **Step 5: Write the fixture-backed end-to-end acceptance spec**

Starting from an empty temporary SQLite database and only sanitized source fixtures:

1. migrate the schema;
2. collect Slack, GitHub for two repositories, and Linear;
3. run identity/cohort/link resolution;
4. collect the identical fixtures again and compare table counts/keys;
5. render default, named secondary, and `all` 7/30/180-day reports;
6. capture canonical results, delete canonical source-domain rows, replace every transport with a fail-on-call fake, and run `reprocess`;
7. assert canonical query results and reports match the pre-delete values;
8. delete every report snapshot and run `rebuild-derived` without source calls;
9. induce one repository failure and assert other repository facts remain plus affected `all` metrics become partial.

Do not compare volatile database IDs or snapshot creation timestamps. Compare stable domain keys, typed metric results, and normalized rendered output with the report timestamp frozen.

- [ ] **Step 6: Write focused data-quality invariants**

Add assertions/queries proving:

- every canonical GitHub/Linear row has a corresponding retained source observation;
- no canonical metric query reads payload JSON;
- source-record payload hashes equal recomputed canonical JSON hashes;
- source-record evidence/identity columns reject attempted model updates, while replay may update only `normalizer_version`;
- foreign keys pass `PRAGMA foreign_key_check`;
- there is exactly one configured/database default repository;
- no duplicate GitHub review IDs, repository-qualified commit keys, or Linear issue IDs;
- no overlapping role assignment for the same person/source/title evidence interval;
- every cached report's semantic inputs can be reconstructed;
- no secret-shaped configured values are present in SQLite text columns.

- [ ] **Step 7: Write setup, operation, and interpretation documentation**

`README.md` must cover:

- `mise install`, `mise exec -- bundle install`, `mise exec -- bin/setup`;
- copying `config/devdash.example.yml` and `config/people.example.yml` to ignored local files;
- required read-only credentials/scopes and `gh auth status`;
- configuring several repositories with exactly one default;
- `sync`, `backfill`, `report`, `reprocess`, `rebuild-derived`, and `doctor` examples;
- SQLite/source-record retention and a backup recommendation;
- metric definitions, attribution rules, repository scope, peer cohort, `n`, partial coverage, and zero-versus-unavailable behavior;
- why activity counts are context rather than performance scores;
- how EngThrive organizes output and how SPACE/DevEx reveal gaps;
- why DORA remains service-level and why Thriving requires private perceptual data;
- explicit V1 privacy boundary: no Slack messages, Calendar, token spend, surveys, CI, deployments, incidents, publishing, or composite score;
- the additive future-source seam: foundation identity/run/evidence/coverage/window/metric infrastructure is reused while each future source adds canonical domain tables.

Update `config/devdash.example.yml` with overlap, initial-backfill, safety-margin, file-exclusion, repository-mapping, and freshness settings used by the implementation. Every option needs a conservative documented default.

- [ ] **Step 8: Run final automated and manual CLI verification**

```bash
mise exec -- bundle exec rspec
mise exec -- bin/devdash --help
mise exec -- bin/devdash report --help
mise exec -- bin/devdash doctor --help
mise exec -- ruby -e 'require_relative "lib/devdash"; puts "load-ok"'
git diff --check
```

Expected: full suite passes, help exits `0`, requiring the library prints only `load-ok`, and the diff check is clean. Also run the fixture-backed report once for default, secondary, and `all`, then inspect that signal roles, sample sizes, partial coverage, framework gaps, and repository breakdowns are understandable without consulting the code.

- [ ] **Step 9: Perform requested review gates**

Use a fresh Luna reviewer for spec compliance against the approved design and this plan. Resolve findings, rerun focused/full verification, then use a second fresh Luna reviewer for code quality, privacy, query correctness, idempotency, and migration safety. The root agent independently verifies all completion claims before accepting either review.

- [ ] **Step 10: Commit Task 13**

```bash
git add lib/devdash/sync_runner.rb lib/devdash/doctor.rb lib/devdash/commands/doctor.rb lib/devdash/cli.rb config/devdash.example.yml README.md spec/devdash/sync_runner_spec.rb spec/devdash/doctor_spec.rb spec/devdash/end_to_end_spec.rb spec/devdash/data_quality_spec.rb
git commit -m "Complete private dashboard acceptance workflow"
```

---

## Design-to-Plan Coverage Matrix

| Approved design requirement | Implementation tasks | Acceptance evidence |
|---|---:|---|
| Ruby 4.0.1 local CLI and SQLite | 1–2 | CLI smoke, schema/model specs |
| Multiple repos, one default, explicit alias/full-name/`all` scopes | 1, 6, 8–13 | scope specs, collector isolation, golden reports, end-to-end selectors |
| Immutable lossless evidence, normalized canonical facts, disposable caches | 2–4, 6–9, 13 | hash/idempotency specs, offline replay, cache rebuild, data-quality invariants |
| Incremental cached collection with independent coverage/cursors | 3, 5–7, 13 | cursor rollback, overlaps, open/active refresh, partial-repo failure |
| Slack identity/title data only | 5, 8 | endpoint allowlist and role/cohort specs |
| GitHub PR/review/commit/file facts grouped by repo | 6, 10 | canonical keys and hand-calculated metric specs |
| Linear creation/completion/flow plus repo mapping | 7–8, 11 | attribution, observed-diff, multi-repo/unmapped specs |
| Current vs previous 7/30/180 days | 9, 12–13 | half-open window specs and all-window end-to-end reports |
| Similar-role/level peers with per-person aggregation and visible `n` | 8–9, 12 | cohort exclusions, distribution specs, golden output |
| EngThrive organization and SPACE/DevEx coverage | 9–13 | definition validation, framework block, golden output |
| No composite score; directionless activity; DORA service-level only | 9, 12–13 | prohibited-ranking specs, renderer assertions, documentation |
| Calendar, AI spend, surveys, CI/deployment/incidents deferred but additive | 2, 9, 13 | shared foundation schema and documented future-source seam |
| Local privacy, credential redaction, no publication path | 1, 4–7, 12–13 | ignored paths, transport redaction, endpoint boundary, docs |

## Execution Handoff

The requested execution mode is already selected: use Luna subagents through `superpowers:subagent-driven-development`. Begin with Task 1 in the current repository only after creating the isolated implementation worktree required by the skill. Pause at both declared parallel-wave merge gates to review and integrate before dispatching downstream tasks.
