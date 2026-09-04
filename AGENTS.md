# Devdash agent instructions

Devdash is a private, local self-improvement dashboard. Keep all work scoped to
the local repository and its owner; do not add publishing, team dashboards,
ranking, compensation, or surveillance features.

## Toolchain and verification

- Use the repository-pinned Ruby 4.0.1 through `mise`.
- Prefer `rg`, `jq`, and `ast-grep` for search and structural inspection.
- Run focused specs first, then the full suite:

  ```sh
  MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" mise --quiet exec -- bundle exec rspec spec/devdash/<area>
  MISE_TRUSTED_CONFIG_PATHS="$PWD/mise.toml" mise --quiet exec -- bundle exec rspec
  ```

- A nested `mise` config-tracking warning can affect CLI smoke stderr in
  restricted worktrees. Record it as an environment issue; do not weaken
  product assertions to hide it.
- Run `git diff --check` and Ruby syntax checks under the pinned toolchain
  before committing.

## Data and privacy invariants

- `source_records` are immutable, lossless sanitized observations. Never delete
  or overwrite them to make a report or test pass.
- Canonical source-domain tables are normalized projections and may be rebuilt
  offline. Report snapshots and other derived caches are disposable only.
- New durable schema requires a numbered migration; migration `005` is the
  current latest migration, so the next new migration is `006`.
- Keep provider credentials out of YAML, fixtures, logs, reports, and SQLite
  payloads. Sanitize errors before persistence or display.
- Slack collection is limited to identity/title data. Authentication failures
  must raise and be persisted as failed runs; never silently continue.
- Preserve unresolved and ambiguous identity/repository evidence. Do not guess
  from display names or collapse multi-repository Linear issues into one repo.

## Architecture boundaries

- Collectors fetch provider data idempotently with source-specific cursors and
  coverage. Normalizers project retained observations into typed tables.
- Metrics query typed canonical columns, never `SourceRecord#payload_json`.
- Repository selectors are configured aliases, full `owner/name`, or `all`;
  default repository behavior must remain explicit and deterministic.
- Metrics must expose definitions, versions, units, signal roles, directionality,
  framework mappings, coverage, and repository breakdowns. Do not add a
  composite score or a leaderboard of named people.
- DORA remains service-level and unavailable until deployment/incident sources
  exist. Thriving requires private perceptual data. Calendar and OpenAI/
  Anthropic token-spend sources are deferred but the data model must remain
  extensible for them.

## Change workflow

1. Read the relevant design and implementation-plan section before editing.
2. Keep independent source/metric namespaces independent; update the shared
   loader only at an integration task.
3. Add deterministic, sanitized fixtures and tests for new behavior.
4. Commit the completed slice with a descriptive message and push its branch;
   merge and push `main` only after focused and full verification.
5. Report product failures separately from local tool, network, or credential
   blockers. Never swallow authentication or transport errors.
