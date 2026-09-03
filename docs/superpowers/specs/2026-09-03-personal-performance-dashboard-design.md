# Personal Performance Dashboard Design

**Date:** 2026-09-03

**Status:** Draft for user review

**Audience:** Private, single-user dashboard for self-improvement

## Summary

Devdash is a local Ruby application that incrementally collects engineering activity from GitHub, Linear, and Slack into SQLite, then renders command-line reports for rolling 7-, 30-, and 180-day windows. Multiple GitHub repositories are configured explicitly, exactly one is the default report scope, and an `all` scope aggregates every enabled configured repository. Each report compares the owner with:

1. the immediately preceding equal-length window; and
2. engineers in a similar role and level during the same window.

Version 1 includes GitHub activity, Linear work, Slack-derived cohort identity, SQLite persistence, and CLI reporting. Calendar and OpenAI/Anthropic usage are deferred, but the shared identity, source-record, collector-run, time-bucket, and metric-versioning primitives are designed so those sources can be added with additive migrations rather than a redesign.

The product will not calculate a composite performance score. Activity counts such as commits and changed lines are presented as context alongside flow metrics, not as direct measures of engineering value.

## Goals

- Produce a private, local report for rolling 7-, 30-, and 180-day windows.
- Show the owner's value, prior-period value and delta, data coverage, and a peer distribution/sample size wherever the comparison is valid.
- Group repository-related metrics by repository.
- Allow reports and backfills to select the default repository, any configured repository, or all configured repositories.
- Collect data idempotently and avoid unnecessary network requests on repeated reports.
- Preserve enough source evidence to correct identity mappings and revise metric definitions without refetching all history.
- Make partial or stale data visible rather than silently reporting incomplete results.
- Support deterministic daily execution without depending on an interactive coding agent.
- Leave clean extension points for Calendar, AI usage/cost, CI, deployment, and incident sources.
- Use EngThrive, SPACE, DevEx, and DORA to keep the metric portfolio multidimensional and correctly scoped.

## Non-goals for Version 1

- Calendar or meeting-time collection.
- OpenAI or Anthropic token and cost collection.
- HTML or hosted reporting.
- Slack message-content or message-volume analysis.
- CI, deployment, incident, or DORA metrics.
- A management dashboard, employee-evaluation tool, or composite engineer ranking.
- Real-time collection or webhooks.
- Automatic inference of a repository when evidence is ambiguous.
- Inferring satisfaction, cognitive load, flow state, or wellbeing from repository telemetry.
- Attributing application- or team-level DORA outcomes to an individual engineer.

## Design Principles

### Separate evidence from interpretation

Collectors preserve source observations, while normalized domain tables and metric queries interpret them. A changed metric definition should normally require a local recomputation, not an API backfill.

### Use domain tables, not a universal EAV schema

Pull requests, reviews, commits, and Linear issues have distinct invariants and receive explicit tables. A generic `source_records` table preserves source payload versions and ingestion provenance. Future sources share foundational primitives but add their own domain tables.

### Model events and observations explicitly

The database distinguishes:

- when an activity happened (`occurred_at`);
- when the source says the object changed (`source_updated_at`); and
- when Devdash observed it (`observed_at`).

All timestamps are stored in UTC. Report windows are half-open intervals: `[start_at, end_at)`.

### Prefer reproducibility over clever inference

Identity matches, role normalization, repository exclusions, and Linear-to-repository mappings are inspectable and locally overridable. Unknown or ambiguous data remains visibly unmapped.

### Distinguish outcome, diagnostic, activity, and guardrail signals

Every metric declares its role:

- **Outcome:** whether valuable work moved through the system successfully.
- **Diagnostic:** a possible explanation for an outcome or a point of friction.
- **Activity:** evidence that work occurred, without an implied productivity direction.
- **Guardrail:** evidence that improvement is sustainable and is not degrading quality or developer thriving.

Reports never blend these roles into one score. The owner's longitudinal trend is primary; peer distributions provide context rather than a competition.

## Measurement Framework

No single research framework fits a private individual dashboard exactly. Devdash uses each framework for the job it does well.

### EngThrive: primary report organization

EngThrive organizes the dashboard into **Speed**, **Ease**, and **Quality**, with **Thriving** as a guardrail. Within each dimension, outcome-oriented North Star signals are paired with diagnostic signals.

Version 1 has more diagnostics than true North Stars because GitHub and Linear stop at merge/completion rather than production or customer outcomes. The report states this limitation instead of relabeling activity as impact.

- **Speed:** Version 1 PR ship time and Linear queue/cycle time; later deployment lead time and throughput consistency.
- **Ease:** Version 1 review pickup time; later aging work in progress, blocked time, CI feedback time, and developer-reported friction.
- **Quality:** Version 1 reopened tickets; later reverted changes, follow-up fixes, deployment failures, and deployment rework.
- **Thriving:** explicitly unavailable from telemetry in Version 1; a later private self-report can measure it directly.

### SPACE: metric-portfolio coverage check

SPACE prevents the dashboard from collapsing productivity into activity. Each release documents which dimensions it covers:

| SPACE dimension | Version 1 treatment |
|---|---|
| Satisfaction and wellbeing | Not inferred; planned private self-report |
| Performance | Shipped/completed work and rework diagnostics; customer outcome data deferred |
| Activity | Commits, changed lines, PRs, reviews, and tickets, clearly labeled contextual |
| Communication and collaboration | Review breadth and responsiveness; no Slack message counting |
| Efficiency and flow | PR/ticket cycle time, wait time, WIP, and aging work |

A release should cover at least three SPACE dimensions and combine system telemetry with perceptual data once surveys exist. Missing dimensions remain visible in a framework-coverage section.

### DevEx: friction model

DevEx contributes three dimensions:

- **Feedback loops:** review pickup/follow-up time and, later, build/test/deploy feedback time.
- **Cognitive load:** requires direct self-report; ticket churn, high WIP, and tooling failures may be diagnostics but are not substitutes.
- **Flow state:** requires direct self-report; future Calendar focus blocks and interruption patterns are supporting context only.

This distinction prevents the dashboard from claiming that a calendar gap proves flow or that a large PR proves cognitive load.

### DORA: later service-level delivery outcomes

DORA's current five-metric model comprises change lead time, deployment frequency, failed deployment recovery time, change fail rate, and deployment rework rate. These measure the delivery performance of an application or service and are shared system outcomes.

When deployment and incident sources are added, Devdash will show DORA metrics by application/service and may show the owner's participation in relevant changes or recovery work. It will not calculate an individual DORA score or compare engineers by DORA outcomes.

### Developer Thriving: planned guardrail instrument

EngThrive's Thriving guardrail can be informed by the separate Developer Thriving research model: agency, motivation/self-efficacy, learning culture, and support/belonging. These are perceptual constructs and require a private, periodic self-report using documented survey provenance. Repository, Slack, or Calendar activity cannot stand in for them.

## System Architecture

```text
GitHub (`gh api`) ───────┐
Linear GraphQL API ──────┼─> source transports -> collectors -> SQLite
Slack Web API ───────────┘                              │
                                                       v
                                          metric query registry
                                                       │
                                                       v
                                               CLI report renderer
```

The application is a standalone Ruby project, not Rails. It uses Active Record as a small persistence and migration layer over SQLite, Ruby's standard option parsing for the CLI, and RSpec for tests. This keeps Rails-familiar persistence semantics without adding a web framework or application server.

### Runtime boundary

MCPs and coding-agent plugins are useful for exploration and authentication discovery, but they are not the unattended application runtime. Daily collection must use deterministic transports:

- GitHub uses authenticated `gh api` commands.
- Linear uses its GraphQL API with a read-only personal/API token.
- Slack uses the Web API with the narrowest available read scopes.

Each collector depends on a transport interface rather than shell or HTTP details. A future MCP-export transport may be added without changing normalization or reporting.

## Proposed Project Layout

```text
bin/devdash
lib/devdash/
  cli.rb
  configuration.rb
  database.rb
  collectors/
    base.rb
    github.rb
    linear.rb
    slack.rb
  transports/
    command.rb
    http.rb
  ingestion/
    batch.rb
    normalizer.rb
  identity/
    resolver.rb
    role_normalizer.rb
  metrics/
    registry.rb
    github/
    linear/
  reporting/
    comparison.rb
    terminal.rb
db/migrations/
config/
  devdash.example.yml
  people.example.yml
spec/
docs/superpowers/specs/
```

Files containing credentials, the SQLite database, report caches, and local identity overrides are ignored by Git.

## Repository Configuration and Scope

Repositories are an explicit configuration boundary. Devdash does not scan every accessible GitHub repository unless each repository is enabled in configuration.

```yaml
github:
  repositories:
    - name: starburstlabs/crm-web
      alias: crm-web
      default: true
      enabled: true
    - name: starburstlabs/repo1
      alias: repo1
      enabled: true
    - name: starburstlabs/repo2
      alias: repo2
      enabled: true
```

Configuration rules:

- Repository identity always uses the full `owner/name`; a short alias is presentation and CLI convenience.
- Exactly one enabled repository must have `default: true`.
- Aliases must be unique and cannot be `all`.
- `all` is a virtual report scope containing every enabled configured repository; it is not stored as a fake repository row.
- Disabled repositories retain previously collected history but are omitted from sync, `all`, and normal report selection until explicitly re-enabled.
- Reports label the aggregate `All configured repos (N)` so it cannot be mistaken for every repository in the GitHub organization.

Omitting `--repo` selects the configured default. Both aliases and full names are accepted. Examples:

```text
devdash report --window 30d                  # crm-web
devdash report --window 30d --repo repo1
devdash report --window 30d --repo all       # all configured repos
```

An internal `RepositoryScope` value contains the resolved repository IDs, display label, and a stable configuration hash. The same scope object is used by synchronization, metric queries, peer comparison, coverage checks, and report caching.

## Component Responsibilities

### CLI

The CLI exposes these user workflows:

- `devdash sync`: run all enabled collectors incrementally across all enabled configured repositories.
- `devdash sync SOURCE`: run one collector; the GitHub collector accepts `--repo SCOPE`, while Slack and Linear remain organization/workspace scoped.
- `devdash backfill --days N [--repo SCOPE]`: explicitly extend historical coverage; repository scope limits GitHub work, while required global Linear/Slack coverage remains independently tracked.
- `devdash report --window 7d|30d|180d [--repo SCOPE]`: render a terminal report using local data only; omission selects the default repository.
- `devdash doctor`: validate credentials, source access, identity coverage, cursors, and data freshness without changing source systems.

`report` never performs network access implicitly. A repeat report is therefore fast and cannot unexpectedly consume API quota.

### Transports

Transports implement authenticated pagination and return source-shaped responses. They do not write the database or make metric decisions.

- `CommandTransport` safely invokes `gh api`, captures structured JSON, and never interpolates secrets into logged command strings.
- `HttpTransport` performs Linear and Slack read-only requests, handles pagination, and classifies authentication, rate-limit, transient, and permanent errors.

### Collectors

Each collector translates source responses into an ingestion batch containing:

- raw source observations;
- normalized domain records;
- identity evidence;
- timestamped events when the source provides them;
- the proposed next cursor; and
- coverage metadata.

Collectors never advance their cursor directly. The ingestion layer commits the batch and cursor atomically.

### Ingestion

Ingestion validates a complete batch, then uses one SQLite transaction to:

1. insert previously unseen raw source versions;
2. upsert normalized entities by stable external identity;
3. insert deduplicated events;
4. record coverage and counts; and
5. advance the collector cursor.

If any step fails, the cursor does not advance. Re-running the collector is safe.

### Identity and cohort resolution

The resolver maps GitHub, Linear, Slack, and future Calendar/provider identities to a local person. Automatic evidence is retained, but a local override file is authoritative.

Slack titles are normalized into a role and level, for example:

```text
"Senior Software Engineer II" -> role: software_engineering, level: senior
```

Role assignments are effective-dated. The peer cohort for a report is the set of active human engineers whose normalized role and level match the owner at the report window's end. Bots, guests, deactivated users, unresolved people, and explicit exclusions are omitted.

For a single repository, comparisons use only matching peers with activity in that repository during the trailing 180 days. For `all`, the eligible cohort is the union of matching peers active in at least one configured repository during the trailing 180 days. Each peer's facts are aggregated across the exact same repository set before distribution statistics are calculated; raw events from all peers are never pooled together. Every comparison displays its sample size, and insufficient samples are labeled rather than extrapolated.

### Metric registry

Each metric is implemented as a named, versioned query object with documented:

- event or entity being counted;
- window boundary behavior;
- attribution rule;
- grouping dimensions;
- exclusions;
- unit and aggregation;
- interpretation direction, if any; and
- metric version;
- signal role (`outcome`, `diagnostic`, `activity`, or `guardrail`);
- measurement scope (`individual`, `team`, or `service`);
- collection mode (`telemetry` or `self_report`); and
- mappings to applicable EngThrive, SPACE, DevEx, or DORA dimensions.

Metric formulas live in Ruby/SQL code, not editable database expressions. Cached report results include the metric version and source watermark, so changing a definition invalidates only affected report caches.

### Reporting

For each metric, reporting can show:

- owner value in the current window;
- owner value in the previous equal-length window;
- absolute and percentage change;
- peer median and interquartile range;
- owner percentile when a higher/lower direction is genuinely meaningful;
- sample size; and
- source coverage and freshness.

Counts are shown both absolutely and per active weekday in Version 1. Calendar-aware working-day normalization is deferred. Duration distributions use median and p75 rather than means.

## Data Model

### Foundation tables

#### `organizations`

Represents the company/workspace boundary shared by source accounts.

#### `people`

Stores the local canonical person, display name, active flag, human/bot classification, and `is_owner` flag.

#### `source_identities`

Maps `(source, external_id)` to a person and stores source login, normalized email when available, observed display name, resolution method, confidence, and observation timestamps.

A unique constraint on `(source, external_id)` prevents one external identity from resolving to multiple people. Person merges update foreign keys transactionally and retain an audit record.

#### `person_merge_audits`

Records the source and destination people, merge timestamp, reason, and configuration/evidence reference so an incorrect identity merge can be diagnosed and repaired.

#### `role_assignments`

Stores original title, normalized role, normalized level, source, `effective_from`, `effective_until`, and `observed_at`. Overlapping assignments from different sources are allowed; configured source priority and manual overrides determine the effective assignment.

#### `repositories`

Stores GitHub repository identity, full name, unique configured alias, Git default branch, enabled/default-report flags, active/archived state, and configured inclusion/exclusion metadata. SQLite enforces at most one default row; configuration validation requires exactly one enabled default.

#### `collector_runs`

Stores source, start/end timestamps, status, cursor before/after, requested and achieved coverage, page/record counts, retry counts, and sanitized error details.

Statuses are `running`, `succeeded`, `partial`, or `failed`. An interrupted `running` record is reported as stale on the next invocation.

#### `collector_run_coverages`

Stores per-run coverage by repository/source scope and entity type. For example, GitHub PR coverage can succeed for `crm-web` while commit coverage for `repo1` fails. An `all` report is complete only when every included repository has sufficient coverage for every source entity required by the metric.

#### `sync_cursors`

Stores one opaque cursor per collector and scope, plus its last successful update. Cursor changes occur only inside the ingestion transaction.

#### `source_records`

Stores versioned raw observations with:

- source and entity type;
- source scope key, such as the repository ID for repository-bound GitHub objects;
- stable external ID;
- source update timestamp;
- observation timestamp;
- canonical payload hash; and
- JSON payload.

The unique key `(source, scope_key, entity_type, external_id, payload_hash)` makes repeated identical fetches no-ops while preserving materially changed source versions and avoiding collisions when the same commit SHA exists in multiple repositories.

#### `metric_definitions` and `report_snapshots`

`metric_definitions` records metric key, version, unit, description, signal role, measurement scope, and collection mode. `metric_framework_mappings` associates a metric version with zero or more framework dimensions without forcing one framework's taxonomy into another. `report_snapshots` optionally caches rendered/structured results using window, repository-scope hash, cohort-definition hash, metric versions, and source-watermark hash. Because reports are local and cheap, this cache is an optimization; source caching and idempotent ingestion provide the required network savings.

### GitHub tables

#### `pull_requests`

Stores repository, number, GitHub node ID, author, state, draft state, opened/closed/merged timestamps, merge commit, additions, deletions, changed-file count, base branch, and source timestamps. Repository plus PR number is unique even when a globally unique node ID is available.

#### `pull_request_events`

Stores deduplicated timeline events such as review requested, ready for review, closed, reopened, and merged. Actor identity is nullable when GitHub does not provide or resolve it.

#### `pull_request_reviews`

Stores the stable GitHub review ID, pull request, reviewer, state, and submission timestamp. Review comments do not create additional review submissions.

#### `pull_request_file_stats`

Stores per-file additions, deletions, status, and exclusion category for the final PR diff. These rows allow shipped-line metrics to exclude generated, vendored, and lockfile paths without trying to reconstruct accumulated commit churn.

#### `commits`

Stores repository, SHA, author/committer identities, authored/committed timestamps, parent count, default-branch reachability observation, and association with a pull request when known. Repository plus SHA is the stable identity because the same Git object may exist in more than one configured repository.

#### `commit_file_stats`

Stores per-file additions, deletions, status, and exclusion category for direct/default-branch commit analysis. PR-level shipped-line metrics use the final PR diff and do not sum these rows.

### Linear tables

#### `linear_issues`

Stores stable issue ID and identifier, creator, current assignee, team/project/state, estimate, priority, created/started/completed/canceled timestamps, and source timestamps.

#### `linear_issue_events`

Stores timestamped assignment, state, estimate, project, and reopen changes when available. Actor identity remains nullable when Linear provides the transition but not its author.

#### `issue_repository_links`

Links issues to repositories with evidence type, confidence, and primary flag. Evidence priority is:

1. linked GitHub pull request;
2. explicit configured Linear project/team/label mapping; and
3. manual override.

An issue linked to multiple repositories is grouped under `multi-repo` unless a primary repository is explicitly resolved. A single-repository report uses only primary links for its main ticket metrics and lists related unresolved multi-repository issues separately. An `all` report includes the `multi-repo` and `unmapped` buckets and counts each issue once.

### Planned additive tables for known future sources

These tables are part of the architectural contract but are not created in Version 1 migrations.

#### `calendar_events`

Will reference `people` and store provider event identity, start/end timestamps, status, event type, owner response, all-day flag, attendee count/category, recurrence identity, and privacy-minimized classification. Descriptions, full attendee lists, and meeting content are not required.

#### `availability_intervals`

Will represent working hours, focus time, out-of-office time, holidays, and leave. Report normalization can then move from weekdays to actual available work time without altering existing metric facts.

#### `ai_usage_buckets`

Will store provider, bucket start/end, optional person identity, provider project/workspace/API-key identity, model, service tier, input/cache/output tokens, requests, and attribution confidence.

#### `ai_cost_buckets`

Will store provider, bucket start/end, attribution dimensions, amount, currency, line item, and allocation method. Usage and cost remain separate because provider grouping dimensions do not always align.

#### `survey_instruments` and `survey_responses`

Will store a versioned instrument, question provenance, response scale, requested cadence, private owner responses, and response timestamps. Construct scores remain tied to the exact instrument version. The schema supports DevEx and Developer Thriving self-reports without placing survey answers in generic metric-value columns or comparing a private self-report with peers who did not take the same instrument.

All future tables use the existing person, source identity, collector run, source record, time-window, and metric-versioning infrastructure.

## Version 1 Metric Definitions

### GitHub delivery

- **Merged PRs:** PRs authored by the person, merged into the repository's default branch, and with `merged_at` inside the window, grouped by repository. Restricting the base branch prevents intermediate stacked-branch merges from being counted as independently shipped changes.
- **PR ship time:** elapsed wall-clock time from `opened_at` to `merged_at` for default-branch PRs merged inside the window; report median and p75.
- **Authored commits:** distinct non-merge commits authored by the person and observed reachable from the default branch, with `committed_at` inside the window, grouped by repository.
- **Lines shipped:** additions and deletions from the final per-file diff of PRs authored by the person and merged into the default branch inside the window, grouped by repository. Generated, vendored, lockfile, and configured paths are excluded from the primary figure and shown separately.
- **Direct-push lines:** additions and deletions for default-branch commits not associated with a merged PR. This is separate from PR lines to prevent double counting.

Commit counts and lines are labeled activity context. Merged PRs and ship-time distributions are the primary delivery signals.

### GitHub review

- **Unique PRs reviewed:** distinct non-self PRs with at least one submitted review by the person inside the window.
- **Reviews submitted:** distinct GitHub review IDs submitted by the person inside the window, broken down by approval, comment, and changes requested.
- **Review breadth:** distinct authors and repositories reviewed inside the window.
- **Review pickup time:** request-to-first-review duration only when a reliable review-request event exists; unavailable observations do not become zeroes.

Bot reviews, pending reviews, deleted identities, and individual line comments are excluded from review-submission counts.

### Linear

- **Tickets created:** issues whose creator resolves to the person and whose `created_at` falls inside the window.
- **Tickets completed while assigned:** issues whose assignee resolves to the person at completion and whose `completed_at` falls inside the window. This does not claim that the person performed the state transition.
- **Ticket queue time:** `created_at` to `started_at` for issues started inside the window.
- **Ticket active cycle time:** `started_at` to `completed_at` for issues completed inside the window.
- **Ticket end-to-end time:** `created_at` to `completed_at` for issues completed inside the window.
- **Reopened tickets:** completed issues with a later transition back to a non-terminal state inside the window, when history is available.

Ticket metrics are grouped using `issue_repository_links`, with `multi-repo` and `unmapped` displayed explicitly.

## Repository-scope Aggregation

Repository-aware metrics accept a resolved `RepositoryScope` rather than a nullable repository argument.

### Single-repository scope

- Facts are filtered to the selected repository.
- The peer cohort is role/level-matched and active in that repository during the trailing 180 days.
- Linear main metrics include issues whose primary repository is the selected repository.
- Global metrics without a repository dimension are shown separately and labeled `global`.

### `all` scope

- Facts are filtered to the union of enabled configured repositories.
- Owner and each peer are aggregated independently across that same union before peer medians, ranges, or percentiles are calculated.
- Counts use distinct source identities within their repository-qualified keys. In particular, commit identity is `(repository_id, sha)`, not SHA alone.
- Linear issues are counted once even when they have multiple repository links; unresolved multi-repository and unmapped issues remain visible.
- The report includes both the cross-repository aggregate and a per-repository breakdown.
- The aggregate is marked partial if any included repository lacks required source coverage.

For count metrics, an eligible peer with no matching activity has a value of zero. For duration metrics, a peer with no completed observation is excluded from that metric's distribution and the reduced sample size is shown. This prevents missing durations from becoming artificial zeroes.

## Comparison Semantics

For a requested duration `D` ending at report time `T`:

- current window: `[T - D, T)`;
- previous window: `[T - 2D, T - D)`.

The initial backfill must therefore cover at least 360 days to render both halves of the 180-day comparison. A configurable safety margin allows late updates.

The peer comparison uses the same current window, metric definition, and repository scope. For repository-aware metrics, peer distributions use the scope-specific cohort defined above. The CLI always prints `n`; when fewer than three peers have comparable observations, it prints `insufficient peer sample` rather than a percentile.

Directionless metrics such as meeting load, commits, changed lines, and AI spend do not receive a good/bad percentile. Their distributions are descriptive.

The terminal report is organized by EngThrive dimension, and each row is visibly labeled as outcome, diagnostic, activity, or guardrail. A final coverage block lists SPACE and DevEx dimensions with measured, partial, or unavailable status. Service-scoped DORA metrics appear in a separate section when their sources exist and never enter person-to-person comparisons.

## Synchronization and Cache Strategy

### Initial backfill

The first synchronization fetches at least 360 days plus a configurable safety margin for every enabled configured repository. It records actual source coverage independently for each collector, repository scope, and entity type.

### Incremental collection

Each daily run combines:

- the source cursor or updated-since filter;
- a configurable overlap window for recently mutable objects; and
- explicit refresh of all open PRs and active Linear issues, regardless of age.

Old open items must remain refreshable because they can merge or complete inside the current report window.

GitHub cursors and retry state are repository-qualified so one repository's failure does not discard successful transactions for another. `devdash sync --repo all` expands to independently observable repository sync scopes rather than one opaque organization-wide run.

### Idempotency

- Raw source versions use stable external IDs plus canonical payload hashes.
- Normalized entities upsert by stable external identity.
- Events and reviews use source event/review IDs when available; otherwise they use a documented deterministic key.
- Cursors advance only with a committed ingestion transaction.
- A repeated report performs no source requests.
- A repeated sync may fetch overlap data but produces no duplicate facts.

### Deletion and disappearance

Absence from a paginated response is not deletion evidence. Records are tombstoned only when the source explicitly reports deletion/inaccessibility or a verified full reconciliation proves absence.

## Error Handling and Data Quality

- Authentication failures stop only the affected collector and produce actionable remediation.
- Rate limits record retry metadata and respect provider reset/backoff signals.
- Transient failures use bounded retries with jitter.
- Pagination errors fail the batch; partial pages are not committed as complete coverage.
- A successful collector does not hide another collector's failure.
- Reports show each source's last successful run, achieved coverage, and staleness.
- Metrics whose required source coverage is incomplete are labeled partial or unavailable.
- `all` reports identify each repository responsible for incomplete aggregate coverage.
- Unresolved identities and repository mappings are counted and surfaced by `devdash doctor`.
- Raw payload retention allows normalization bugs to be repaired locally.

## Security and Privacy

- All data remains local by default.
- Source tokens are read from environment variables or the operating-system credential store; they are never stored in SQLite or committed files.
- The application requests read-only and least-privilege scopes.
- Logs redact tokens, authorization headers, emails when unnecessary, and response bodies on authentication failures.
- The SQLite file and generated reports are ignored by Git and created with owner-only permissions where supported.
- Slack is used only for identity and role evidence in Version 1; no messages are collected.
- Future Calendar collection stores only fields needed for time classification, not descriptions or meeting content.
- Future survey responses remain local and are never included in named peer comparisons unless equivalent, consented cohort survey data exists.
- Reports may contain named peers because the product is private, but no publishing or sharing mechanism is included.

## Testing Strategy

### Unit tests

- Identity resolution, conflicting evidence, manual overrides, and person merges.
- Slack-title role normalization and effective-date selection.
- Window boundaries, current/previous comparisons, percentile behavior, and insufficient samples.
- Default, single-repository, and `all` scope resolution, including reserved/duplicate aliases.
- Per-person cross-repository aggregation before cohort distribution calculation.
- Metric role/scope/framework metadata and framework-coverage calculation.
- Repository mapping priority, multi-repository handling, and unmapped totals.
- Exclusion classification for generated, vendored, and lockfile paths.

### Collector contract tests

Every collector is tested against recorded, sanitized fixtures for:

- initial pagination;
- incremental pagination/cursors;
- mutable overlap reconciliation;
- old open-item refresh;
- rate limiting and transient retries;
- partial-page failure;
- identical re-run idempotency; and
- changed-source-version ingestion.

### Integration tests

- SQLite migrations from an empty database.
- Atomic batch and cursor behavior under injected failures.
- GitHub review-ID deduplication across event and comment feeds.
- Linear transitions without actors.
- Full 360-day current/previous report coverage.
- Independent per-repository cursor advancement and partial `all` coverage.
- Distinct cross-repository aggregation, including identical commit SHAs in different repositories.
- Report-cache invalidation after data or metric-version changes.

### Report tests

Sanitized golden outputs verify the CLI's default/single/`all` repository selection, EngThrive sections, signal-role labels, framework coverage, columns, repository grouping, sample sizes, partial-data warnings, and stable formatting. Tests assert that activity signals and service-scoped DORA metrics cannot be rendered as individual performance rankings. Metric fixture tests use hand-calculated expected values rather than snapshots alone.

### Live smoke tests

Opt-in smoke tests validate credentials and minimal read access for each source without changing remote state. They are not part of the default test suite.

## Delivery Slices

### Version 1: foundation and core dashboard

- Ruby project foundation, configuration, Active Record, and SQLite migrations.
- Multiple configured repositories, exactly one default, and explicit single/`all` repository scopes.
- Collector/transport/ingestion contracts and provenance tables.
- Slack people/title collection and local identity overrides.
- GitHub repository, PR, review, commit, and file-stat collection.
- Linear issue/history collection and repository linking.
- Versioned metric registry and 7/30/180-day comparisons.
- EngThrive-organized terminal renderer, SPACE/DevEx coverage, and `doctor` diagnostics.

### Version 2: time, focus, and experience

- Google Calendar incremental synchronization.
- Calendar event classification and overlap-safe duration calculations.
- Availability-aware workday normalization and meeting/focus metrics.
- Versioned private DevEx/Developer Thriving self-report instruments.
- Telemetry-versus-perception comparisons without causal claims.

### Version 3: AI economics

- OpenAI organization usage and cost collection.
- Anthropic organization usage and cost collection.
- Optional gateway or local-agent usage imports.
- Attribution-confidence reporting and token/cost metrics.

### Later slices

- CI and deployment feedback loops.
- Incident and reliability outcomes, including service-scoped DORA metrics.
- Static HTML reporting and historical visualization.

## Acceptance Criteria for Version 1

- Running `devdash sync` twice against unchanged fixtures produces identical normalized rows and no duplicated events.
- Configuration accepts multiple repositories, rejects zero/multiple defaults and reserved/duplicate aliases, and resolves omitted `--repo` to the default.
- For reports, `--repo crm-web`, any other enabled configured alias/full name, and `--repo all` select the expected repository set.
- A failed page or normalization step cannot advance a cursor or claim complete coverage.
- Failure in one repository is visible without discarding successfully committed data for other repositories, and makes an affected `all` metric partial.
- A 180-day report can compare against the preceding 180 days after the initial backfill.
- GitHub metrics are grouped by repository and distinguish PR-shipped lines from direct-push lines.
- Review counts deduplicate by review ID and exclude line-comment inflation.
- Linear metrics distinguish creator attribution, assignee-at-completion attribution, and unknown transition actors.
- Every metric shows current, previous, delta, peer distribution/sample size when valid, and source coverage.
- `all` reports aggregate each person across the same configured repository set before calculating peer distributions, count multi-repository Linear issues once, and include a per-repository breakdown.
- Every metric declares its signal role, measurement scope, collection mode, and applicable framework mappings.
- Reports are organized by EngThrive, expose SPACE/DevEx coverage gaps, and never rank individual engineers with activity-only or service-scoped DORA signals.
- Slack titles produce an inspectable normalized cohort, and local overrides can correct any match or title classification.
- Missing identities, mappings, permissions, or source coverage are visible through the report and `doctor` command.
- Calendar and AI usage can be added through new collectors/domain tables while reusing people, identities, source records, collector runs, time semantics, and metric versioning.

## Research References

- [DORA software delivery performance metrics](https://dora.dev/guides/dora-metrics/)
- [The SPACE of Developer Productivity](https://www.microsoft.com/en-us/research/publication/the-space-of-developer-productivity-theres-more-to-it-than-you-think/)
- [DevEx: What Actually Drives Productivity?](https://doi.org/10.1145/3610285)
- [EngThrive: Make It Fast and Easy to Do Great Work](https://www.microsoft.com/en-us/research/publication/engthrive-make-it-fast-and-easy-to-do-great-work/)
- [Developer Thriving: Four Sociocognitive Factors That Create Resilient Productivity on Software Teams](https://dsl.pubpub.org/pub/dev-thriving/release/2)
