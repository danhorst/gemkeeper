# Spec 20260529-131354: Server-authoritative sync cache check

## Overview

`gemkeeper sync` decides a gem is "already synced" by checking for a local build artifact, but the running server serves from a separate store populated only by HTTP upload. These two states can diverge, so a fresh or repointed server can never be repopulated by re-running `sync` — every gem is skipped and nothing is uploaded, leaving the server returning 404 for gems that exist on disk. This spec makes `sync`'s skip decision authoritative against the server's *private* store via a new read-only endpoint, and lets `sync` recover by re-uploading an already-built artifact without rebuilding.

## Goals

- `sync` skips a gem only when the running server's private store actually serves that exact version.
- The presence check consults the private store only — never the upstream-proxied compact index — so it cannot be fooled by a public gem of the same name and never probes rubygems.org.
- A fresh, empty, or repointed server is fully repopulated by re-running `sync`, with no manual cache clearing.
- For pinned and `from_lockfile` versions, recovery never re-clones or rebuilds when the `.gem` artifact already exists locally. (`version: latest` keeps today's always-fetch behavior — see FR-1.6.)
- No regression to the shared Homebrew-service deployment, where `sync`'s `gems_path` legitimately differs from the server's.

---

## Feature 1: Server-authoritative sync skip and recovery

**Who & why:** A developer working offline runs `gemkeeper sync` to populate a local gem server, then `bundle install` against it. Today, if they restart the server against an empty store (or it was never uploaded to), `sync` silently skips every gem because the local `.gem` files still exist, and `bundle install` fails with 404s that give no hint the cache is stale. They need `sync` to detect that the *server* is missing a gem and fix it, so "run sync, then bundle" always works.

### Functional Requirements

#### FR-1.1: Skip decision queries the server's private store, not the local filesystem
`GemSyncer` determines whether a gem version is already available by asking the running server's private store, replacing the current `cached?` check that tests for a local file at `gems_path/<name>-<version>.gem`. A gem is considered present only if the server's private store reports that exact `<name>` and `<version>`. The version comparison uses bare semver (no `v` prefix), consistent with existing cache-key normalization.
**Verify:** With a `.gem` present in the local `gems_path` but absent from the server's store, `sync` reports the gem as synced (not skipped) and the server subsequently serves it; with the gem present on the server, `sync` reports it skipped.

#### FR-1.2: Presence is read from the private-store endpoint, not `/info`
The server-presence check calls the dedicated private-store endpoint defined in FR-2.1 (`GET /gemkeeper/has/<name>/<version>`), not the Bundler-facing `/info/<name>`. A `200` means present; a `404` means not present. `/info/<name>` is deliberately not used because it falls back to the upstream rubygems.org index (`serve_upstream_info`), which would cause public-name-collision false positives, offline failures, and leakage of private gem names to rubygems.org.
**Verify:** A unit test stubs `GET /gemkeeper/has/mimir/1.0.5` returning `200` → present; stubs `404` → not present; confirms `sync`'s presence path issues no request to `/info` or to rubygems.org.

#### FR-1.3: Re-upload an existing artifact instead of rebuilding
When the server reports a gem version missing but the corresponding `.gem` already exists in the local `gems_path`, `sync` uploads that existing artifact directly. Before uploading, it verifies the artifact's embedded gemspec name and version match the requested gem; on mismatch or an unreadable artifact it falls through to the build path rather than uploading the wrong file. It does not clone, pull, or run `gem build` when a valid artifact is reused. Only when no valid local artifact exists does `sync` fall back to the full clone/checkout/build path.
**Verify:** With a valid `mimir-1.0.5.gem` in `gems_path` and absent from the server, running `sync mimir` uploads the gem without invoking the git or build steps (assert via stubbed `GitRepository`/`GemBuilder` that they are not called), and the server then serves `mimir 1.0.5`; with a corrupt `mimir-1.0.5.gem`, `sync` does not upload it and proceeds to rebuild.

#### FR-1.4: Idempotent re-sync against any server state
Running `sync` twice in a row is safe and convergent: the first run uploads whatever the server is missing; the second run finds everything present and skips it. If an upload targets a gem the server already has, the server's existing-gem response (`409`, already handled by `GemUploader#handle_response` as success/skip) is treated as success, not failure.
**Verify:** Run `sync` against an empty server, then immediately again; first run uploads N gems, second run skips all N with no errors and a zero failure count.

#### FR-1.5: Output distinguishes the three outcomes
`sync` output distinguishes (a) skipped because the server already has it, (b) uploaded an existing local artifact without rebuilding, and (c) built and uploaded from source. Outcomes (b) and (c) both count as `:synced` in the run summary; only (a) counts as `:skipped`, so the existing `:synced`/`:skipped` tally and `report_results` are unchanged. The distinction between (b) and (c) is conveyed in the per-gem output text using the existing `Output.skip`/`Output.step`/`Output.success` vocabulary, with wording that makes clear when a rebuild was avoided.
**Verify:** Output for a server-present gem shows a "skipped" line and increments `:skipped`; output for an artifact re-upload names that the cached artifact was uploaded without rebuilding and increments `:synced`; output for a fresh gem shows the build step and increments `:synced`.

#### FR-1.6: `version: latest` keeps today's always-fetch behavior
For `version: latest`, the version is only known after clone/checkout (`current_version` post-checkout), so `latest` is exempt from the "skip before fetching" and "re-upload without rebuild" guarantees. `latest` continues to fetch the repo and resolve the gemspec version as it does today (the existing `!gem_def.latest?` cache bypass). Once the version is resolved, the server-presence check still applies to decide whether the resolved version needs uploading.
**Verify:** A `version: latest` gem always fetches the repo; after resolving its gemspec version, if the server already has that version the gem is reported skipped, otherwise it is built/uploaded.

### Architectural Requirements

#### AR-1.1: Presence check lives behind the uploader/server-client seam
The server-presence query belongs with the HTTP client that already owns server communication (`GemUploader`, `lib/gemkeeper/gem_uploader.rb`), which holds `server_url`, a Faraday connection, `reachable?`, and the `POST /upload` call. Add `has_version?(name, version)` there; `GemSyncer` calls it rather than holding HTTP concerns. The existing `list_gems` stub is left as-is (it has its own `gemkeeper list` contract). Reusing the existing Faraday connection (with its `:multipart`/`:url_encoded` middleware) for the GET is acceptable.
**Verify:** `GemSyncer` contains no direct HTTP/Faraday code; `has_version?` is covered by `test/gemkeeper/test_gem_uploader.rb`.

#### AR-1.2: Reuse existing version resolution and cache-key normalization
The presence check and artifact lookup use the version produced by the existing resolution path (`resolve_version`, `latest_version!`, `current_version`) and the bare-semver normalization already applied for cache keys and filenames (`checkout_tag`, the former `cached?`). Artifact filenames are derived one way, as `<name>-<version>.gem` (see the platform assumption in Assumptions & Risks).
**Verify:** A `from_lockfile` gem resolves its version, then the presence check and any upload use that bare version and the `<name>-<version>.gem` filename.

#### AR-1.3: Preserve both deployment modes
The design must not assume `sync`'s `gems_path` equals the server's `gems_path`. In the shared Homebrew-service mode they differ (project-local build dir vs. absolute service store), and the HTTP bridge between them is retained. The presence check is therefore strictly server-side over HTTP, never a local-path comparison against the server's store.
**Verify:** A test exercising a server whose store path differs from `sync`'s `gems_path` still skips/uploads correctly based solely on server responses.

#### AR-1.4: Presence-check status → outcome mapping
`has_version?` maps server responses as follows: `200` → present; `404` → not present; `400` (invalid name/version — should not occur for config-sourced names) → raise as a programming error, not silently "absent"; a connection failure or timeout → `ServerNotReachableError` with the existing "run 'gemkeeper server start'" guidance. Because the skip decision now depends on a server round-trip, an unreachable server surfaces this actionable error early (before any git work) rather than treating the gem as present or absent.
**Verify:** Server down → `sync` exits with the not-reachable error and guidance; `400` → raises a non-`ServerNotReachableError`; `404` → gem treated as not present and the run continues.

#### AR-1.5: `GemSyncer` flow defers source work until after the cheap checks
`GemSyncer#sync` is reordered so that, for pinned and `from_lockfile` versions, the server-presence check and the local-artifact check run before any repo or manifest resolution. Repo URL resolution (`resolve_repo`), `GitRepository` creation, and `clone_or_pull` happen only when a build is actually required. The upload-existing-artifact path and the build-then-upload path are separated (e.g. distinct private methods) rather than the current single `build_and_upload`.
**Verify:** For a pinned gem the server already has, `sync` makes no manifest/repo resolution and creates no `GitRepository` (assert via stubs); the build and upload-existing paths are independently testable.

---

## Feature 2: Private-store presence endpoint

**Who & why:** `sync` needs an authoritative yes/no on whether the server's *private* store holds a specific gem version, without the Bundler `/info/<name>` endpoint's upstream fallback that proxies rubygems.org. A public gem sharing a private gem's name, or an offline upstream probe, must never affect the answer.

### Functional Requirements

#### FR-2.1: Read-only private-store presence endpoint
`CompactIndexServer` exposes `GET /gemkeeper/has/<name>/<version>` that consults the private `GemIndex` only and never invokes the upstream cache. It returns `200` when the index holds `<name>` with a version whose recorded number equals `<version>` (bare semver), and `404` otherwise. The response body is minimal (status is the signal).
**Verify:** With `mimir 1.0.5` uploaded, `GET /gemkeeper/has/mimir/1.0.5` → `200` and `GET /gemkeeper/has/mimir/9.9.9` → `404`; with the server offline and `mimir` absent, the same request returns `404` immediately with no upstream request and no 503.

#### FR-2.2: Name and version validation
The endpoint validates `<name>` with the existing `VALID_NAME` pattern and rejects a malformed name or empty version with `400`, consistent with the server's other parameterized routes.
**Verify:** `GET /gemkeeper/has/..%2Fetc/1.0.0` (or any name failing `VALID_NAME`) → `400`; a well-formed-but-absent gem → `404`.

### Architectural Requirements

#### AR-2.1: Endpoint reads only the private index and follows existing server patterns
The endpoint is wired through the existing router and built with the existing response helpers (`ResponseBuilder`/the small `not_found`/`invalid_name` responders), reading exclusively from `GemIndex` (`@index`) and never touching `UpstreamCache`. It must not regress the server's quality gates (rubocop clean, rubycritic ≥ 90) — keep the routing addition consistent with the `RESOURCE_ROUTES` table approach so `CompactIndexServer` does not gain a new smell.
**Verify:** The endpoint handler references `@index` only (no `@cache`); rubocop and rubycritic remain green after the addition.

---

## Data Requirements

No new persisted data or schema changes. The private-store presence endpoint reads the in-memory `GemIndex` built from the on-disk store; the on-disk layout (`gems_path` for build artifacts, `gems_path/gems` for the served store) is unchanged.

## Integration Points

- `lib/gemkeeper/gem_syncer.rb` — reordered `sync` flow; the `cached?` replacement (presence → re-upload → build/upload); split of `build_and_upload`.
- `lib/gemkeeper/gem_uploader.rb` — new `has_version?(name, version)`; reuses the existing Faraday connection and error mapping.
- `lib/gemkeeper/compact_index_server.rb` — new `GET /gemkeeper/has/<name>/<version>` route.
- `lib/gemkeeper/compact_index_server/gem_index.rb` — read path used by the endpoint (presence lookup against `@index`).
- `lib/gemkeeper/cli/commands/sync.rb` — unchanged wiring (`GemUploader.new(config.server_url)`); the uploader now also answers presence, and `report_results` is unchanged (re-upload counts as `:synced`).

## Related Specs

| Spec | Relationship | Affected Requirements |
|------|-------------|---------------------|
| Spec 20260529-091429: Replace Geminabox with compact index server | **Modifies** — corrects the sync↔serve cache contract introduced when the in-process compact-index server replaced Geminabox, and adds a private-store presence endpoint to that server | FR-1.1, FR-2.1, AR-1.1, AR-1.3 |

## Constraints

- Quality gates must stay green: `bundle exec rubocop` clean and `bundle exec rubycritic lib --no-browser` ≥ 90.
- Follow the established collaborator/value-object structure of the compact-index server refactor; no Metrics-cop suppression comments.
- Offline-first: for pinned and `from_lockfile` versions, the happy path and recovery path must not require network or git access when a valid local artifact exists (FR-1.3); the presence endpoint must never block on an upstream probe (FR-2.1).
- Tests: create `sync()` orchestration tests in `test/gemkeeper/test_gem_syncer.rb` (it currently tests only `resolve_repo`); extend `test/gemkeeper/test_gem_uploader.rb` (presence method) and `test/gemkeeper/test_compact_index_server.rb` (new endpoint); add the original-bug regression to `test/integration/test_server_lifecycle_integration.rb`.
- Add an `[Unreleased]` CHANGELOG entry under `Fixed`.

## Out of Scope

- Flattening the `gems_path` vs `gems_path/gems` layout or eliminating the redundant flat build artifact. This is a tidiness improvement that would change the on-disk layout and require migrating existing Homebrew-service stores; deferred to a future spec.
- Precompiled, platform-specific gem variants (filenames like `<name>-<version>-<platform>.gem`). Internal gems are built from source with the default `ruby` platform (see Assumptions); supporting published per-platform binaries is a future spec.
- Removing or redesigning the HTTP `POST /upload` bridge. It is required for the shared-service mode and is retained as-is.
- Changing the Bundler-facing `/info`, `/names`, `/versions`, or `/gems` endpoints.
- Auto-refreshing the server's in-memory index from disk without an upload. The upload remains the mechanism that informs a running server of a new gem.
- Changing version-resolution semantics (`latest`, `from_lockfile`, tag normalization).

## Assumptions & Risks

- **Platform assumption:** internal gems are built from source via `gem build` and are therefore the default `ruby` platform, producing a single `<name>-<version>.gem` (no platform suffix). This is confirmed by evidence — every gem currently built by `sync` lacks a platform suffix. Gems with C extensions still fall under this assumption (extensions compile at install time); only deliberately cross-compiled, published per-platform binaries would not, and those are out of scope.
- **Presence-implies-serveable invariant:** the private-store endpoint and `/gems/<file>` both read the same `GemIndex`, so a `200` from the presence endpoint implies the binary is serveable. If a future change makes them diverge, the skip decision would become unsafe.
- **`sync` requires a reachable server** (already true today, since it uploads). The presence check makes this dependency explicit and surfaces it earlier (AR-1.4).
- **Risk — artifact identity:** a stale or wrong local `.gem` could be uploaded; mitigated by the pre-upload name+version check (FR-1.3).

## Spec Completeness Checklist

- [x] **Scope & acceptance criteria** — Goals + per-FR **Verify** lines + Out of Scope bound the change; the bug and its reproduction are in Overview/FR-1.1; `latest` is explicitly scoped (FR-1.6).
- [x] **Testing strategy** — Constraints list the files to create/extend (notably new `sync()` tests in `test_gem_syncer.rb`) and the original-bug regression; FR Verify lines define conditions.
- [x] **Existing patterns** — Reuses `GemUploader` HTTP seam, `Output` vocabulary, bare-semver normalization, the router/`RESOURCE_ROUTES` and `ResponseBuilder` patterns (AR-1.1, AR-1.2, AR-2.1, FR-1.5).
- [x] **Dependencies** — No new libraries; reuses the Faraday client and adds one read-only endpoint (FR-2.1, AR-1.1).
- [x] **Architecture & interfaces** — `has_version?` on the uploader; reordered `GemSyncer` flow with split build/upload (AR-1.1, AR-1.5); private-store endpoint reads `@index` only (AR-2.1); data model unchanged.
- [x] **Error handling & failure modes** — Status→outcome mapping incl. `400`/`404`/connection failure (AR-1.4); idempotent/`409` handling (FR-1.4); corrupt/mismatched artifact fallthrough (FR-1.3); offline endpoint returns `404` not `503` (FR-2.1).
- [x] **Security review** — Low (not N/A). The private-store endpoint removes the `/info` upstream fallback, so private gem names are no longer leaked to rubygems.org for the cache check; `<name>` is validated by `VALID_NAME` server-side (FR-2.2) and the client treats `400` as a programming error (AR-1.4). Traffic is loopback; gems are developer-controlled.
- [x] **Performance impact** — One extra loopback `GET /gemkeeper/has/...` per gem (no upstream probe); negligible. Re-upload avoids the far costlier clone/build for pinned/`from_lockfile` (FR-1.3).
- [x] **Rollout & migration** — No data migration; on-disk layout unchanged. New endpoint is additive; behavior change is limited to the skip decision; existing stores keep working.
- [x] **Assumptions & risks** — Platform, presence-implies-serveable, server-reachability, and artifact-identity captured in Assumptions & Risks.

---

## Change Log

### Update from critique-consolidated-v-1.md

**Applied:**
- Replaced the `/info`-parsing cache check with a dedicated private-store endpoint `GET /gemkeeper/has/<name>/<version>` (new Feature 2; FR-1.2, FR-2.1, FR-2.2, AR-2.1) — resolves the upstream-fallback false-positive, offline-503, and private-name-leak findings (critique A, I).
- Scoped the "never re-clone" guarantee to pinned and `from_lockfile` versions; added FR-1.6 making `latest`'s always-fetch behavior explicit (critique B).
- Added the platform assumption (default `ruby` platform, `<name>-<version>.gem`); precompiled per-platform variants moved to Out of Scope (critique C).
- Required a pre-upload artifact identity check (name+version match; corrupt-artifact fallthrough) in FR-1.3 (critique D).
- Specified the `GemSyncer` flow change — defer repo/manifest resolution until after the presence and local-artifact checks, and split `build_and_upload` (AR-1.5) (critique E).
- Added the presence-check status→outcome mapping (AR-1.4) and decided third-outcome counting: re-upload counts as `:synced`, differentiated by output text only, leaving the CLI summary unchanged (FR-1.5) (critique F).
- Clarified `has_version?` is added and `list_gems` is left as-is; noted Faraday connection reuse is acceptable (AR-1.1) (critique G, H).
- Updated testing constraints to create `sync()` tests in `test_gem_syncer.rb` plus the original-bug regression and listed scenarios.
- Downgraded the security review from N/A to low-with-mitigations.

**Rejected:**
- None. (Flattening the `gems_path/gems` layout was raised as adjacent messiness but was already deliberately out of scope; left out of scope.)

**Reorganized:**
- Split the single feature into Feature 1 (client-side sync behavior) and Feature 2 (server-side private-store endpoint) so the new server surface has its own FRs/ARs.
