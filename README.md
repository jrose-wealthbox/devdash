# Devdash

Devdash is a private, local self-improvement dashboard for software engineers. It compares an engineer’s GitHub and Linear signals with a deliberately narrow peer cohort—people at the same role and level—and compares the current 7-, 30-, and 180-day windows with the immediately preceding windows.

The dashboard is context, not a performance score. Activity volume is not automatically good or bad, people are not ranked, and service-level DORA signals are never attributed to an individual. Every report shows sample size (`n`), repository scope, coverage, freshness, and known gaps.

## Setup

Devdash uses Ruby 4.0.1, SQLite, and the read-only provider interfaces already available in your local environment.

```sh
mise install
mise exec -- bundle install
mise exec -- bin/setup
```

Create local configuration files. They are ignored by Git and should remain private:

```sh
cp config/devdash.example.yml config/devdash.yml
cp config/people.example.yml config/people.yml
```

Edit `config/devdash.yml` with the repositories you want to scan. Configure several repositories if useful, but set `default: true` on exactly one enabled repository. The selectors accepted by reports and sync are an alias (`crm-web`), a full GitHub name (`starburstlabs/crm-web`), or `all`.

Configure `config/people.yml` with the owner’s source identities and role/level. Manual mappings are preferred when an identity is ambiguous. Slack supplies display names and job titles; no Slack message content is collected.

The provider credentials are read-only. Authenticate GitHub with the GitHub CLI and verify it before syncing:

```sh
gh auth status
```

The GitHub account needs read access to each configured repository, including pull requests, reviews, timelines, files, commits, and search. Linear requires a read-only API key with issue, history, team/project, label, and attachment visibility. Slack requires a token that can call `users.list` (normally `users:read`). Store `LINEAR_API_KEY` and `SLACK_TOKEN` in the environment or your local secret manager; never put them in YAML or SQLite.

## Daily operation

The normal daily run is:

```sh
mise exec -- bin/devdash sync --repo all
```

Source selection is also available when debugging a provider:

```sh
mise exec -- bin/devdash sync github --repo crm-web
mise exec -- bin/devdash sync linear
mise exec -- bin/devdash sync slack
```

`all` expands GitHub into one sequential run per enabled repository, then runs the global Linear and Slack scopes. A failed repository does not cancel the other units; the command attempts all requested units and exits nonzero if any unit failed. Failed source runs retain the prior cursor and coverage. Slack authentication errors are intentionally loud and are persisted as failed runs with sanitized diagnostics.

For an explicit historical fetch:

```sh
mise exec -- bin/devdash backfill --days 180 --repo all
```

The first incremental sync requests at least 360 days plus the configured safety margin. Later runs use a 48-hour overlap by default. Open GitHub pull requests and active Linear issues are refreshed even when their update timestamp falls outside the incremental interval.

Render a report at a frozen point in time when comparing runs:

```sh
mise exec -- bin/devdash report --window 7d --repo crm-web
mise exec -- bin/devdash report --window 30d --repo repo1
mise exec -- bin/devdash report --window 180d --repo all --at 2026-09-03T12:00:00Z
```

Offline maintenance commands never construct provider transports:

```sh
mise exec -- bin/devdash reprocess
mise exec -- bin/devdash rebuild-derived
mise exec -- bin/devdash doctor --offline
```

`reprocess` rebuilds normalized projections from retained source observations. `rebuild-derived` clears disposable report snapshots so they can be regenerated. `doctor` prints every diagnostic and exits `0` when there are no errors, `1` when remediation is needed. Without `--offline`, doctor performs narrow read-only access probes for GitHub, Linear, and Slack.

## Data safety and retention

The SQLite database retains immutable, canonicalized `source_records`: one lossless sanitized provider observation identified by source, scope, entity, external ID, and payload hash. Typed domain tables—GitHub pull requests, reviews, commits and files; Linear issues, histories, and repository evidence; Slack identities and titles—are normalized projections of those observations. Report snapshots are disposable caches.

This separation is intentional. Reporting can change without refetching providers, and a projection can be deleted and reconstructed offline. Source evidence columns reject ordinary model updates; replay may only advance normalizer metadata. Back up `data/devdash.sqlite3` before experimenting with migrations or deleting evidence. The database may contain private work metadata, names, job titles, and email evidence, so protect the file and its backups with user-only permissions.

## What the report means

The current V1 signals include:

- GitHub authored commits, changed lines, merged pull requests, review submissions, unique pull requests reviewed, review pickup time, pull-request ship time, and review breadth.
- Linear tickets created, completed while assigned, reopened tickets, queue time, active cycle time, and end-to-end completion time.
- Repository breakdowns for configured repositories, with explicit multi-repository and unmapped Linear attribution retained rather than silently guessed.

Each metric has a definition, version, unit, signal role, directionality, collection mode, required coverage, and framework mapping. Outcome, diagnostic, activity, and guardrail signals are shown separately. A zero means the query found a measured zero in covered data; an unavailable value means the required source or coverage is missing. A partial result is labeled with the affected source or repository.

The peer cohort is active human contributors with the same normalized role and level as the owner and qualifying activity in the trailing 180 days. Bots, guests, inactive people, merged records, unresolved/ambiguous identities, explicitly excluded people, role mismatches, and people without in-scope activity are shown as exclusions. Reports show the cohort size and distribution rather than a leaderboard.

## EngThrive, SPACE, DevEx, and DORA

EngThrive is the organizing frame for the report: speed, ease, quality, and thriving. In V1, the telemetry proxies primarily illuminate delivery flow and engineering-system friction; they do not measure the whole experience of being an engineer.

SPACE and DevEx help interpret the gaps:

- SPACE keeps activity, performance, communication/collaboration, efficiency/flow, and satisfaction from collapsing into one number.
- DevEx separates the inner loop, feedback loops, and cognitive/friction costs from outcomes. Long pickup time or queue time can reveal system friction even when output volume looks high.
- DORA is service-level. Deployment frequency, lead time for changes, change failure rate, and recovery time require deployment and incident data, which V1 does not collect and therefore cannot attribute to an individual.
- Thriving needs private perceptual data such as surveys or interviews. V1 deliberately does not collect those signals, so the Thriving block reports that it is unavailable rather than pretending telemetry is a substitute.

Use the dashboard to ask better questions: what changed, is the source complete, is the comparison cohort large enough, and what context explains the signal? Do not use it for compensation, ranking, surveillance, or a composite score.

## Privacy boundary

V1 collects only the provider facts needed for the documented GitHub, Linear, and Slack identity/title metrics. It does not collect Slack messages, Google Calendar events, OpenAI or Anthropic token spend, surveys, CI runs, deployments, incidents, or manager assessments. It has no publishing, webhook, or team-facing dashboard path. Calendar, OpenAI/Anthropic spend, perceptual surveys, CI/deployment/incident sources are deferred, but the shared identity, run, evidence, coverage, window, and metric infrastructure is designed so each future source can add canonical tables without changing existing evidence.

## Development

Run the suite with the repository’s pinned toolchain:

```sh
mise exec -- bundle exec rspec
mise exec -- bin/devdash --help
mise exec -- bin/devdash report --help
mise exec -- bin/devdash doctor --help
mise exec -- ruby -e 'require_relative "lib/devdash"; puts "load-ok"'
```

Keep provider fixtures sanitized and deterministic. Add a migration for durable schema changes, keep source observations lossless and immutable, and make new collectors idempotent with independent cursors and coverage. Reporting and presentation changes should operate from canonical tables or replayed projections, not raw payload JSON.
