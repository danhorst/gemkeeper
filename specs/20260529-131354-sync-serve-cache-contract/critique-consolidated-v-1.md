# Spec 20260529-131354: Consolidated Critique (v1)

## Overview

**Critiques received from:** Claude, Codex, Copilot (claude-sonnet-4.6)
**Critiques missing:** Gemini (not installed; Copilot used as the third critic)

## Executive Summary

All three critics agree the spec targets the right bug with the right shape (server-authoritative skip + artifact re-upload, uploader-seam placement, both deployment modes preserved). But they converge on one finding that **undercuts the chosen mechanism**: `GET /info/<name>` is *not* a private-store-authoritative signal. `CompactIndexServer#serve_info` falls back to `serve_upstream_info` (rubygems.org) when the gem isn't in the private `GemIndex` (`compact_index_server.rb:74`). That breaks the presence check two ways:

1. **Public name-collision false positive** — a public gem sharing the private gem's name/version makes `/info` return 200, so `sync` wrongly skips while the private store is still missing the artifact (Codex risk 1, Claude point 2).
2. **Offline failure / slow recovery** — a missing private gem triggers an *upstream* probe with 5s/10s timeouts, returning **503** (not 404) when offline. The spec only treats 404 as "not present," and 503 is exactly the recovery scenario the spec exists to fix (Copilot MR-2, Codex risk 2).

This means **Q1 (the cache-check mechanism) needs to be reconsidered**: "reuse `/info`, no new server surface" is not actually authoritative. The fix is either a private-store-only signal (small dedicated endpoint, or a flag/header on the existing one) or a checksum comparison. The dedicated-endpoint option I originally dismissed is now the better-justified path.

Beyond that, the strongest convergent gaps are the `version: latest` contradiction, platform filenames, the `build_and_upload` decomposition, and HTTP-status handling.

## Consolidated Requirements Feedback

### A. `/info` is not private-authoritative (mechanism flaw) — HIGHEST PRIORITY
**Issue:** The presence check must reflect only the private uploaded store, never the upstream-proxied merge.
**Agreement:** All three. Codex and Copilot independently trace the `serve_upstream_info` fallback; Claude flagged the public-name-collision edge.
**Divergence:** Mechanism. Codex: add a private presence contract *or* a checksum-based rule. Copilot: at minimum treat 503 as not-present. Claude: pin an AR that presence is read only from the private index.
**Recommendation:** Reverse the Q1 decision toward a **private-store-only presence signal**. Cleanest: a tiny read-only endpoint that consults `GemIndex` only (e.g. `GET /gemkeeper/has/<name>/<version>` → 200/404, or `HEAD /gems/<file>` wired to the private store), returning unambiguous present/absent with no upstream probe. This also removes the private-name leak to rubygems.org and the offline-timeout problem in one move. If avoiding a new endpoint is still preferred, define a checksum rule and explicit 503-means-not-present handling — but the endpoint is simpler and more correct.

### B. `version: latest` contradicts "never re-clone"
**Issue:** Goals promise recovery never re-clones, but `latest` resolves its version only post-checkout, so it must clone first.
**Agreement:** All three (Claude point 4, Codex risk 3, Copilot MR-1/PI-1).
**Recommendation:** Pick one and write it down: (a) scope the no-reclone guarantee to pinned + `from_lockfile` versions, and state `latest` keeps today's always-fetch behavior; or (b) for `latest` with a local artifact, read the version from the artifact via `Gem::Package.new(path).spec.version` to avoid cloning. (a) is the smaller, safer change and matches today's `!gem_def.latest?` cache bypass; recommend (a) unless offline `latest` recovery is a stated requirement.

### C. Platform filenames
**Issue:** Presence is framed as `(name, version)`, but artifacts/served files can be `<name>-<version>-<platform>.gem` (`SpecMapper.filename`).
**Agreement:** Claude point 1, Codex risk 4.
**Recommendation:** Either declare private gems pure-Ruby (filename `<name>-<version>.gem`) as an explicit assumption, or make presence/artifact lookup operate on the exact filename including platform. Given these are internal source-built gems, the pure-Ruby assumption is likely fine — but it must be stated.

### D. Artifact integrity before re-upload
**Issue:** FR-1.3 re-uploads a local `.gem` without validating it; a partial/corrupt artifact (interrupted build) would fail server-side in `GemIndex#add` (`Gem::Package.new(...).spec`).
**Agreement:** Codex (missing req), Copilot EH-3.
**Recommendation:** Require a pre-upload integrity/identity check — parse the artifact's spec and confirm name+version match the requested gem before declaring success — or explicitly scope corrupt-artifact handling out. Recommend the lightweight check; it also closes Codex's "upload the wrong thing" concern.

### E. `build_and_upload` decomposition unspecified
**Issue:** FR-1.3 needs an upload-without-build path, but `GemSyncer#build_and_upload` does both unconditionally and the spec doesn't name the structural split.
**Agreement:** Copilot MR-3, Codex "refactoring GemSyncer ordering."
**Recommendation:** Add an AR naming the flow: defer repo/manifest resolution until after the server-missing check; separate "upload existing artifact" from "build then upload." This also matters because today `sync` resolves the repo *before* the cache check (`gem_syncer.rb:21`) — ordering must change.

### F. HTTP status handling + counting/messaging
**Issue:** AR-1.4 covers unreachable + malformed but not the full status matrix (400/500/503), and the CLI summary only knows `:synced`/`:skipped` while the spec introduces a third outcome.
**Agreement:** All three.
**Recommendation:** Add a status table: 200→inspect, 404 (and 503-from-upstream-miss, if `/info` is retained)→not present, 400→programming error (raise, not "absent"), connection failure→`ServerNotReachableError`. Define whether artifact re-upload counts as `:synced` (recommended; differentiate via output text only) or a new symbol that `run_sync`/`report_results` must learn.

### G. Faraday connection reuse for GET
**Issue:** `GemUploader#connection` carries `:multipart`/`:url_encoded` middleware meant for `POST /upload`; reusing it for a GET is wasteful and theoretically fragile.
**Agreement:** Copilot CA-1.
**Recommendation:** Acceptable to reuse (note it), or use a plain connection for read requests. Low priority.

### H. `list_gems` vs `has_version?` ambiguity
**Issue:** AR-1.1's "e.g. `has_version?` / replacing the `list_gems` stub" conflates two different contracts.
**Agreement:** Copilot AM-1.
**Recommendation:** State explicitly: add `has_version?(name, version)` (or the chosen private-presence call); leave or remove `list_gems` deliberately, not as a side effect.

### I. Security is not strictly N/A
**Issue:** The `/info` upstream fallback can leak private gem names to rubygems.org; client doesn't validate the name before building the URL.
**Agreement:** Codex (FAIL), Copilot (defense-in-depth note).
**Recommendation:** If the private-endpoint fix (A) is adopted, the leak disappears. Regardless, add a note: client treats 400 as a programming error; gem names come from config/manifest and should match `VALID_NAME`. Downgrade from "N/A" to "low, with these mitigations."

## Additional Requirements Identified

- **AR:** Presence is determined solely from the private index, never an upstream-proxied response (resolves A, I).
- **AR:** Repo/manifest resolution is deferred until after the server-presence and local-artifact checks (resolves E).
- **FR:** Before re-uploading an existing artifact, verify its embedded spec name+version match the requested gem (resolves D).
- **FR/AR:** Define the presence-check HTTP status → outcome mapping (resolves F).
- **Testing:** `test_gem_syncer.rb` currently tests only `resolve_repo` — `sync()` orchestration tests must be **created**. Add integration coverage for: empty server + local artifact (the original bug), divergent server `gems_path`, offline upstream, upload 409 conflict, and public-name collision (all critics).

## Ambiguities Requiring Clarification

1. **Mechanism for private-authoritative presence** (new endpoint vs. checksum vs. retained `/info` + 503 handling) — the central open decision.
2. **`latest` scope** — accept always-fetch, or add artifact version-read path.
3. **Platform** — pure-Ruby assumption or full filename matching.
4. **Third-outcome counting** — `:synced` vs new symbol.

## Summary of Required Changes

1. **Reconsider Q1:** make the presence check private-store-authoritative (recommend a small read-only private endpoint; eliminates name-collision, offline-503, and name-leak issues at once).
2. Resolve the `latest` / "never re-clone" contradiction (recommend: scope guarantee to pinned + `from_lockfile`).
3. State the platform assumption (recommend: private gems pure-Ruby, filename `<name>-<version>.gem`).
4. Require pre-upload artifact identity check (name+version match).
5. Specify the `GemSyncer` flow change: defer repo/manifest resolution; split build vs. upload-existing.
6. Add the HTTP status→outcome table and the third-outcome counting decision.
7. Resolve `list_gems`/`has_version?`; note Faraday connection choice.
8. Update testing: create `sync()` tests + the listed integration scenarios; downgrade security from N/A with explicit mitigations.

## Verdict

Right problem, right overall shape, well-bounded scope — but **NEEDS WORK before implementation**, primarily because the recommended `/info` mechanism isn't private-authoritative. That single decision (change A) cascades into the security and offline-503 items. With A resolved plus the `latest`, platform, decomposition, and status-handling tightenings, this is ready to implement.
