# Critique: Server-authoritative sync cache check

## Overview

The spec targets the right bug: `sync` currently treats a flat local build artifact as proof that the running compact-index server can serve the gem.
Moving the skip decision to a server-side check and re-uploading existing artifacts is the right shape, but the proposed `/info/<name>` contract is not yet authoritative enough because that endpoint is merged with the RubyGems upstream cache.

## Approach Summary

- Put the presence check in `GemUploader`, keeping HTTP concerns out of `GemSyncer`.
- Replace the local `cached?` skip with a server query, then choose skip, upload existing artifact, or build and upload.
- Reuse existing version normalization for fixed tags, `from_lockfile`, and `latest`.
- Keep the current `POST /upload` bridge and avoid assuming `sync` and server `gems_path` are the same.
- The major under-justified choice is "no new server endpoint": current `/info/<name>` is not private-store-only, so using it as the authoritative signal has correctness, privacy, and performance consequences.

## Risks

1. `/info/<name>` can report an upstream public gem, not just a privately uploaded gem.
   Likelihood: medium.
   Severity: high.
   `CompactIndexServer#serve_info` falls back to `serve_upstream_info` when `@index[gemname]` is absent (`lib/gemkeeper/compact_index_server.rb:74`), so a public gem with the same name/version could make `sync` skip even though the private server store is missing the intended artifact.
   The spec does not address this.

2. Offline recovery can stall or fail on upstream RubyGems lookups.
   Likelihood: high for the stated offline use case.
   Severity: high.
   A missing private gem causes `/info/<name>` to probe RubyGems through `GemCache#info` (`lib/gemkeeper/compact_index_server/gem_cache.rb:20`), with 5s open and 10s read timeouts in `RubygemsClient` (`lib/gemkeeper/compact_index_server/rubygems_client.rb:15`).
   The spec says 404 means not-present, but offline misses may return 503 after waiting, which conflicts with the goal of fast local recovery.

3. `version: latest` conflicts with the no-git recovery goal.
   Likelihood: high.
   Severity: medium.
   The spec says `latest` must resolve from the checked-out gemspec before presence checking (`spec.md:49`), which requires clone/pull via the existing `GemSyncer` flow (`lib/gemkeeper/gem_syncer.rb:30`).
   That contradicts the goal that recovery never re-clones when an artifact exists unless the spec explicitly scopes that guarantee to fixed or `from_lockfile` versions.

4. Existing artifact selection can upload the wrong thing or miss valid platform gems.
   Likelihood: medium.
   Severity: medium.
   The spec repeats the current `gems_path/<name>-<version>.gem` shape, but the server stores platform filenames as `<name>-<version>-<platform>.gem` via `SpecMapper.filename` (`lib/gemkeeper/compact_index_server/spec_mapper.rb:13`).
   It also does not require validating that a reused local artifact's embedded gemspec name/version matches the requested gem before declaring success.

5. Security is not actually N/A.
   Likelihood: medium.
   Severity: medium.
   The client will construct a path from a config/manifest gem name, and `Configuration::GemDefinition` validates version but not name.
   The server validates names after routing (`lib/gemkeeper/compact_index_server.rb:49`), but the client still needs path-segment escaping and the `/info` fallback can leak private gem names to RubyGems.org.

## Complexity Hotspots

### Making `/info` Authoritative

This is the hardest part.
The endpoint is a Bundler-facing merged compact index endpoint, not a private-store API.
If the spec keeps "no new endpoint," it needs a precise rule for distinguishing private presence from upstream presence, probably by comparing the compact-index checksum to the local artifact when one exists or by changing server behavior for sync-specific checks.

### Refactoring `GemSyncer` Ordering

Current `sync` resolves the repo before cache handling (`lib/gemkeeper/gem_syncer.rb:21`) and fetches the repo before `latest_version!`.
To satisfy "upload existing artifact without git/build," implementation likely must defer repo resolution and `GitRepository` creation until after the server-missing/local-artifact path.
The spec names the high-level flow but does not call out this ordering change.

### HTTP Status And Parse Semantics

The presence method needs exact status handling: 200 parse, 404 absent, 400 invalid config/name, 503 upstream unavailable, 5xx server failure, redirects, and Faraday connection failures.
AR-1.4 currently says both "erroring server" maps to `ServerNotReachableError` and "malformed `/info`" means not-present, which leaves important cases open.

### Counting And Messaging

FR-1.4 says an upload conflict is "success/skip," while FR-1.1 says re-uploaded missing gems report as synced, not skipped.
The existing CLI summary only knows `:synced` and `:skipped` (`lib/gemkeeper/cli/commands/sync.rb:40`), so the spec should say how conflict, re-upload, and freshly built upload affect the summary counts.

## Missing Or Ambiguous Requirements

- Define whether "server reports exact version" means private uploaded gem only, merged private-or-public compact index entry, or matching checksum for the exact artifact.
- Specify how `GET /info/<name>` names are encoded and what happens when the server returns 400 for an invalid name.
- Clarify whether 503 from upstream miss while the local server is otherwise healthy should mean not-present or hard failure.
- State whether local artifact reuse requires reading the `.gem` spec and verifying expected name/version/platform before upload.
- Specify platform gem behavior: exact filename lookup, multiple artifacts for one name/version, and whether any platform version is considered present.
- Clarify the `latest` guarantee: either accept that it still needs git to discover the current version or define a local-artifact discovery rule for latest.
- Require deferring repo and manifest resolution when fixed-version or lockfile-version artifact upload can succeed without source checkout.
- Define how upload conflicts are counted in the sync summary.
- Add acceptance coverage for a server whose `/info` would proxy upstream, not only a stubbed 404.

## Completeness Checklist Audit

| Item                         | Status | Notes |
|------------------------------|--------|-------|
| Scope & acceptance criteria  | WARN   | Main behavior is clear, but `latest`, platform artifacts, and public upstream collisions are not bounded. |
| Testing strategy             | WARN   | Needs `test_gem_syncer.rb` flow tests, CLI summary updates, upstream 503/offline tests, public name collision tests, and platform/corrupt artifact cases. |
| Existing patterns            | WARN   | Correctly uses `GemUploader`, but misses current `GemSyncer` repo-resolution ordering and `CompactIndexServer` upstream fallback behavior. |
| Dependencies                 | PASS   | No new library dependency is needed. |
| Architecture & interfaces    | WARN   | Uploader seam is right, but `/info` is not currently a private-store interface. |
| Error handling & failures    | WARN   | Unreachable server is covered, but HTTP status mapping and upstream 503 are underspecified. |
| Security review              | FAIL   | The N/A claim misses private-name leakage to RubyGems.org, client path encoding, and local artifact validation. |
| Performance impact           | FAIL   | The spec assumes one cheap loopback GET, but misses per-gem upstream lookups and offline timeout behavior. |
| Rollout & migration          | PASS   | No data migration is needed and existing stores can remain in place. |
| Assumptions & risks          | WARN   | Identifies `/info` parsing risk, but misses that `/info` is merged/proxied rather than private authoritative. |

## Verdict

NEEDS WORK.

The intended sync behavior is implementable, but the spec needs to resolve the `/info` authority problem, offline 503 behavior, artifact validation, and `latest` semantics before implementation can proceed without guessing.

## Suggested Next Steps

1. Decide whether the authoritative check must be private-store-only.
   If yes, either add a private presence contract or specify a checksum-based rule that cannot be fooled by upstream public gems.
2. Clarify fixed, `from_lockfile`, and `latest` flows separately, including exactly when repo/manifest resolution is required.
3. Specify local artifact lookup and validation, including platform suffixes and corrupt/wrong gem files.
4. Define presence-check HTTP status handling and output/counting semantics.
5. Update the test plan to include syncer-level orchestration tests plus integration coverage for empty server, offline upstream, divergent server path, upload conflict, and public name collision.
