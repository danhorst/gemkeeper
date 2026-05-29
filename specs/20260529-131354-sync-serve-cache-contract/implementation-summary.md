# Implementation Summary: 20260529-131354-sync-serve-cache-contract

**Status:** Completed
**Date:** 2026-05-29

## Overview

Made `gemkeeper sync`'s skip decision authoritative against the server's *private* store instead of a local build artifact, fixing the bug where a fresh or repointed server could never be repopulated (every gem skipped, 404s on `bundle install`). Added a private-store-only presence endpoint, server-authoritative `serves?` on the uploader, and reordered `GemSyncer` to defer repo work — skipping when the server already has a gem and re-uploading an existing artifact without rebuilding.

## Execution

Solo, sequential (the client depends on the server endpoint contract): server endpoint → client `serves?` → `GemSyncer` reorder → tests → quality-gate refactor.

## Files Created
- `lib/gemkeeper/repo_fetcher.rb` — `RepoFetcher`: resolves a gem's repo URL (manifest + override) and clones/pulls it, with git-auth error mapping. Extracted from `GemSyncer` to keep it under the rubycritic gate.
- `test/gemkeeper/test_repo_fetcher.rb` — repo-resolution tests (migrated from `test_gem_syncer.rb`).

## Files Modified
- `lib/gemkeeper/compact_index_server.rb` — new `GET /gemkeeper/has/<name>/<version>` route (`serve_presence`) + `present` responder; reads the private index only.
- `lib/gemkeeper/compact_index_server/gem_index.rb` — `serves?(name, version)` predicate over the in-memory index.
- `lib/gemkeeper/gem_uploader.rb` — `serves?(name, version)` (hits the private endpoint; 200/404/else→`ServerError`; connection failure→`ServerNotReachableError`); extracted `not_reachable!` helper.
- `lib/gemkeeper/gem_syncer.rb` — reordered: `sync_pinned` (server check → artifact reuse → build) / `sync_latest` (always fetch); `reusable_artifact?` identity check; delegates repo acquisition to `RepoFetcher`.
- `lib/gemkeeper.rb` — require `repo_fetcher`.
- `test/gemkeeper/test_compact_index_server.rb` — 4 presence-endpoint tests.
- `test/gemkeeper/test_gem_uploader.rb` — `serves?` connection-failure test.
- `test/gemkeeper/test_gem_syncer.rb` — `reusable_artifact?` (4) + `sync()` orchestration (2) tests; resolve tests moved out.
- `test/integration/test_server_lifecycle_integration.rb` — original-bug regression + skip-when-served tests.
- `test/integration/test_cli_integration.rb` — repurposed the obsolete local-cache-skip test to assert the new unreachable-server error.
- `CHANGELOG.md` — `[Unreleased]` Fixed entry.

## Test Results
`bundle exec rake test` → 230 runs, 512 assertions, 0 failures, 0 errors.
`bundle exec rubocop` → 76 files, no offenses.
`bundle exec rubycritic lib --no-browser` → 90.13 (gate ≥ 90); `gem_syncer` B, `repo_fetcher` A, no C/D/F.

## Spec Adherence
| Requirement | Status | Implementation | Test |
|-------------|--------|---------------|------|
| FR-1.1 | Done | `gem_syncer.rb` `sync_pinned`/`sync_latest` via `@uploader.serves?` | `test_sync_skips_when_server_already_serves` (unit + integration) |
| FR-1.2 | Done | `gem_uploader.rb` `serves?` hits `/gemkeeper/has` | `test_gem_uploader`, presence endpoint tests |
| FR-1.3 | Done | `reusable_artifact?` + `reupload` | `test_sync_reuploads_existing_artifact_without_rebuild`, regression |
| FR-1.4 | Done | `GemUploader#handle_response` 409→skip | `test_sync_skips_when_server_already_serves` (runs sync twice) |
| FR-1.5 | Done | `skip`/`reupload`/`build_gem` symbols + output text | syncer unit tests, integration `1 skipped` |
| FR-1.6 | Done | `sync_latest` always fetches | covered by `sync_latest` path |
| FR-2.1 | Done | `compact_index_server.rb` `serve_presence` + `GemIndex#serves?` | `test_presence_endpoint_*` (incl. no-upstream-probe) |
| FR-2.2 | Done | `serve_presence` `VALID_NAME` check → 400 | `test_presence_endpoint_rejects_invalid_name` |
| AR-1.1 | Done | `serves?` on `GemUploader`; `list_gems` untouched | `test_gem_uploader` |
| AR-1.2 | Done | reuse `resolve_version`; `<name>-<version>.gem` | syncer tests |
| AR-1.3 | Done | presence strictly over HTTP | integration (real server) |
| AR-1.4 | Done | status mapping in `serves?` | `test_serves_raises_server_not_reachable_on_connection_failure`, CLI unreachable test |
| AR-1.5 | Done | `RepoFetcher` deferral; build/upload split | unit stubs assert no fetch/build on skip/reuse |
| AR-2.1 | Done | endpoint reads `@index` only; gates green | rubycritic 90.13 |

## Deviations from Spec
- **`RepoFetcher` extraction (not in the spec's file list).** The `GemSyncer` reorder added methods and pushed it to a rubycritic C (120); reek flagged `resolve_repo` and the auth helpers as belonging elsewhere. Extracting `RepoFetcher` both satisfied the spec's quality-gate constraint and is the cleaner boundary (sync orchestrates; `RepoFetcher` acquires the repo). The 6 repo-resolution tests moved with it. No behavior change.
- **`test_cli_integration#test_sync_skips_already_cached_gem` repurposed.** It asserted the old local-cache skip (no server) that the spec deliberately removes; rewritten as `test_sync_errors_when_server_unreachable` to assert the new server-authoritative guard (AR-1.4).

## Living docs
`specs/docs/` does not exist — skipped. Run `/spec-docs --full` to bootstrap if desired.
