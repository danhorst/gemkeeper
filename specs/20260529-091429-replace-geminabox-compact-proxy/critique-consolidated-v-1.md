# Spec 20260529-091429: Consolidated Critique (v1)

## Overview

**Critiques received from:** Claude, Copilot, Codex
**Critiques missing:** None

## Executive Summary

All three critics reached the same verdict: the direction and architecture are sound, but the spec is not implementation-ready.
The blocking issues cluster around three areas: the `/versions` merge algorithm is underspecified in ways Bundler will exercise directly; ETag/digest header generation for merged responses is absent; and security input validation is incorrectly dismissed.
There are also several codebase assumptions that don't match reality (GemUploader response codes, `rubygems-generate_index` dependency, `list_gems` dead method).
The fixes are additive — the spec doesn't need restructuring, just more precision in the places listed below.

---

## Blocking Issues (must resolve before implementation)

### B-1. `/versions` merge algorithm is underspecified

All three critics flagged this.
The spec says private gems "take precedence" when a name appears in both, but doesn't define the algorithm.

The problems:

1. **Collision semantics** — does "private takes precedence" mean: replace the entire public entry (suppressing all public versions), replace only matching version entries, or append a private-wins line and rely on Bundler's last-entry behavior? If public versions remain visible, a developer pulling `rails 7.1.0` from the private gem (a fork) will still see public rails versions and Bundler may resolve the wrong one (dependency confusion).

2. **Byte stability** — Bundler caches the byte offset of the last `/versions` line it fetched and issues `Range: bytes=N-` on subsequent requests. If the merge interleaves private gems by insertion date, any new private gem shifts offsets of everything after it, corrupting Bundler's incremental update. The spec must define a stable layout: e.g., upstream public block verbatim first, private gem entries appended at the end.

3. **`VersionsFile` API** — `CompactIndex.versions(versions_file, extra_gems)` takes a `CompactIndex::VersionsFile` object backed by a cached file, not a raw upstream response string. The spec must describe how the upstream body is persisted to disk and surfaced as a `VersionsFile`.

**Recommendation:**
- Cache the raw upstream `/versions` response verbatim to `cache_dir/rubygems_cache/versions`.
- Construct a `VersionsFile` from that cached file.
- Pass private gems as `extra_gems` so they are appended after the public block — this preserves byte stability for the public block.
- "Precedence" means private gem entries replace the matching public name in `extra_gems` merge (public versions for colliding names are suppressed).

### B-2. ETag and `Repr-Digest` for merged responses must be computed from the merged body

The spec requires these headers (FR-1.3) but does not say how to derive them for merged responses.
All three critics noted this independently.

Forwarding the upstream `ETag` or `Repr-Digest` header from RubyGems.org is wrong — the merged body differs from the upstream body, so Bundler's SHA256 verification will fail and it will retry unconditionally.

**Recommendation:** For all endpoints serving merged or locally-generated content (`/versions`, `/info/:gemname` for private gems, `/names`), compute `ETag` and `Repr-Digest: sha-256=<base64>` from the final response body. Do not forward upstream headers unchanged.
Pick SHA256 for ETag (avoids a second hash pass; consistent with `Repr-Digest`).

### B-3. `info_checksum` has a circular dependency

Copilot and Claude both identified this.
`CompactIndex::GemVersion#info_checksum` is the SHA256 of the `/info/:gemname` response body.
To populate it in `/versions`, the server must generate the `/info` body first, hash it, and embed the hash.
An implementer who builds the versions index before the info bodies will produce invalid checksums, causing Bundler to re-fetch unconditionally.

**Recommendation:** Add an AR stating: info bodies for all private gems are generated first; their SHA256 checksums are computed and stored in memory; then the `/versions` index is built referencing those checksums. Checksums are recomputed after each successful upload.

Also note: Codex flagged that `CompactIndex::GemVersion` may use `number` rather than `version` as the field name in 0.15.x. Verify the actual field names against the installed gem before implementation.

### B-4. `/names` scope is undefined

Copilot and Codex both flagged this.
RubyGems.org `/names` is ~2.7 MB / ~175,000 entries.
FR-1.1 says `/names` returns "all gem names (local and proxied)" but doesn't say whether the server fetches, caches, and merges the upstream `/names` file or scopes to a smaller subset.

These produce different behavior:
- Full public namespace: correct, but expensive.
- Local-only + cached: bundle install fails on any public gem not already in the info cache.

**Recommendation:** Treat `/names` consistently with `/versions` — fetch and cache the upstream `/names` file; merge with local private gem names; apply the same ETag/cache TTL rules as `/info/:gemname`.

---

## Significant Gaps

### G-1. Path traversal in `/gems/:filename.gem`

All three critics raised this.
The spec's security checklist marks this N/A because the server binds to 127.0.0.1.
Localhost binding does not prevent path traversal — any local process can issue a crafted request.
A filename like `../../gemkeeper.pid` resolves outside `gems_path/gems/`.
The same `gemname` parameter is used to construct `https://rubygems.org/info/:gemname`, creating an SSRF vector if unvalidated.

**Recommendation:** Add a validation constraint: `:gemname` and `:filename` URL parameters are validated against `/\A[a-zA-Z0-9._-]+\z/` before any filesystem or upstream URL construction. Return 400 otherwise. Additionally, assert the resolved file path is under `gems_path/gems/` before serving.

### G-2. "Valid gem" definition in FR-1.2 is ambiguous

All three critics flagged this.
Three interpretations exist: (1) correct `.gem` extension; (2) parseable tar archive containing `metadata.gz`; (3) `metadata.gz` can be loaded as a Ruby gemspec without errors.
Option 3 is dangerous — loading a gemspec can execute arbitrary Ruby.

**Recommendation:** Specify option 2: validate that the file is a tar archive containing `metadata.gz` and `data.tar.gz`. Parse gemspec metadata from `metadata.gz` using `Gem::Package.new(path).spec` inside a rescue block. If parsing raises, return 422. Do not `load` or `eval` gemspec content.

### G-3. Upload atomicity and `gems_path/gems/` creation

Codex and Claude raised this.
FR-1.2 does not require `mkdir_p gems_path/gems/` (the subdirectory may not exist on first run), atomic temp-file writes (concurrent uploads of different gems can interleave file writes), or cleanup of temp files after failed validation.

**Recommendation:** Add to FR-1.2: create `gems_path/gems/` if absent before writing; write to a temp file in the same directory first, then `File.rename` to the target path (atomic on POSIX); delete temp file on validation failure.

### G-4. Thread safety for in-memory gem index

Copilot and Codex raised this.
Puma uses a thread pool. A `GET /info/:gemname` concurrent with an upload rebuilding the in-memory index produces a data race.

**Recommendation:** Add an AR: the in-memory gem index is replaced atomically via a single instance variable assignment after each full rebuild (copy-on-write pattern). Index reads do not acquire a lock; the rebuild completes into a new object before swapping.

### G-5. Upstream 404 vs outage distinction in FR-3.4

Codex and Copilot raised this.
FR-3.4 says return 404 with `"Upstream unavailable and no local cache"`.
But if RubyGems.org returns a genuine 404 (the gem does not exist), the spec's response body is misleading.
The two cases — "upstream reachable, gem not found" and "upstream unreachable" — should produce different responses.

**Recommendation:** Distinguish: upstream reachable + 404 → return 404 with no body; upstream unreachable (connection error, timeout) + no cache → return 503; upstream unreachable + cache exists → serve from cache with appropriate headers.

### G-6. `GemUploader#list_gems` becomes a dead method

Copilot raised this.
`GemUploader#list_gems` calls `GET /api/v1/gems.json`, a Geminabox-specific endpoint the new server will not implement.
The method is not called in production code (list reads the filesystem), but it is a public method that silently breaks after migration.

**Recommendation:** Either add `GET /api/v1/gems.json` to the Out of Scope list and note that `list_gems` becomes a broken dead method (acceptable since it is unused), or have the server return a 404 for that path and add a note in the spec that the method should be removed or stubbed.

### G-7. `rubygems-generate_index` dependency not addressed

Copilot and Codex both noted that `gemkeeper.gemspec` and `Gemfile` declare `rubygems-generate_index ~> 1.0`, which exists to support Geminabox's legacy Marshal index generation.
The spec swaps `geminabox` for `compact_index` but is silent on this.

**Recommendation:** Add `rubygems-generate_index` to the list of dependencies removed in the Integration Points table.

---

## Additional Requirements to Add

| # | Source | Requirement |
| - | ------ | ----------- |
| AR-new-1 | All | Info bodies computed before versions index; checksums embedded in versions from pre-computed hashes |
| AR-new-2 | All | ETag is SHA256 of merged response body for all locally-generated or merged endpoints |
| AR-new-3 | All | `:gemname` and `:filename` URL params validated to `/\A[a-zA-Z0-9._-]+\z/` before filesystem or upstream URL use |
| AR-new-4 | Copilot/Codex | Puma's thread count should be set to 1 (or the index swap made atomic) — specify which |
| FR-new-1 | All | `/names` fetches, caches, and merges upstream `/names` with local gem names under the same TTL rules as `/info` |

---

## Ambiguities to Resolve

1. **ETag algorithm** — spec says "MD5 or SHA256"; pick SHA256 (consistent with `Repr-Digest`, avoids two passes).
2. **GemUploader response codes** — spec says 201/409; actual `GemUploader#handle_response` also accepts 200 and 302 as success. Align the spec with the real code.
3. **`/versions` cache storage** — spec is ambiguous about whether the cache stores the raw upstream body (re-merged on request) or the merged result (invalidated on upload). Specify: cache raw upstream body; re-merge with private gems in memory on request; memoize the merged result until next upload or upstream ETag change.
4. **`CompactIndex::GemVersion` field names** — verify `number` vs `version` against the installed 0.15.x gem before referencing them in the spec.
5. **AGENTS.md vs CLAUDE.md** — Codex noted the Integration Points table references `CLAUDE.md`, but the actual project instruction file may be `AGENTS.md`. Verify and correct.

---

## Summary of Required Changes

1. **(Blocking)** Specify the `/versions` merge algorithm: upstream verbatim block first, private gems appended via `extra_gems`, collision = suppress public entry, byte-stable layout.
2. **(Blocking)** Specify ETag and `Repr-Digest` computation from merged body for all generated/merged endpoints.
3. **(Blocking)** Specify `info_checksum` generation order: info bodies first, checksums embedded into versions index.
4. **(Blocking)** Define `/names` scope: fetched, cached, merged like `/versions`.
5. Add input validation constraint for `:gemname` and `:filename` path parameters.
6. Clarify "valid gem" validation as tar-parseable + gemspec extractable (no eval).
7. Add upload atomicity requirements: `mkdir_p`, temp-file write, rename.
8. Add thread safety AR: atomic index swap after rebuild.
9. Distinguish upstream 404 vs outage in FR-3.4 (404 vs 503).
10. Note `list_gems` dead method and `rubygems-generate_index` removal in Integration Points.
11. Correct GemUploader response code list (200/201/302 accepted, not just 201).
12. Resolve ETag algorithm ambiguity (SHA256 only).
