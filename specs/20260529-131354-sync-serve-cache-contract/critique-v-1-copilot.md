# Critique: Spec 20260529-131354 — Server-authoritative sync cache check

Reviewer: GitHub Copilot (claude-sonnet-4.6)
Date: 2026-05-29

## Summary

The spec is well-scoped and the core idea is sound.
The major gap is an unresolved contradiction between the Goals and AR-1.2 around `version: latest`, and several smaller gaps in error handling, format parsing, and implementation structure that need tightening before handoff to an implementer.

---

## Missing Requirements

### MR-1: The `version: latest` + clone contradiction is unresolved

The Goals promise "Recovery never re-clones or rebuilds a gem whose `.gem` artifact already exists locally."
AR-1.2 then acknowledges that for `version: latest`, version resolution happens *post-checkout*, meaning `clone_or_pull` still runs before any server check.
These two statements directly contradict each other for the case where a `latest` gem is already on the server.

The spec needs to explicitly choose one of:
(a) The no-reclone goal only applies to non-`latest` gems (add that scope qualifier to the Goals section).
(b) For `version: latest` with a local artifact, read the version from the `.gem` file via `Gem::Package.new(path).spec.version` to avoid cloning, then check the server — add this as a new code path.

Without a resolution, an implementer will produce inconsistent behavior and the Goals will be technically false for `latest` gems.

### MR-2: 503 response from `/info/<name>` is not addressed

When a private gem has never been uploaded to a running server, `GemIndex#[]` returns `nil` for that name.
The server then calls `serve_upstream_info`, which returns 503 (`upstream_unavailable`) when offline.
This is the exact recovery scenario the spec is designed to fix — the gem doesn't exist on the server — yet only 404 is explicitly listed as "not present."
A 503 from the server during the presence check should also be treated as "not present" (or at minimum documented as an expected response that triggers the upload path), but it is not mentioned in FR-1.2, AR-1.4, or the Assumptions & Risks.

### MR-3: No description of how `build_and_upload` is decomposed

FR-1.3 requires a new code path: upload an existing artifact without building.
`GemSyncer#build_and_upload` currently performs both steps unconditionally.
The spec never mentions that this method must be split (e.g., `upload_artifact(gem_path)` vs. `build_gem(local_path, gems_path)`) or what the resulting `GemSyncer` flow looks like.
An implementer must infer the structural change from the FR alone, which increases the chance of inventing different designs across teams or in agentic handoff.

### MR-4: Test file for `sync()` behavior does not yet exist in `test_gem_syncer.rb`

The Constraints point to `test_gem_syncer.rb` for `GemSyncer` test coverage, and FR-1.3's Verify describes stubs for `GitRepository` and `GemBuilder`.
The existing `test_gem_syncer.rb` tests only `resolve_repo` — it has no tests for `sync()` at all.
The spec should acknowledge that new test methods for `sync()` must be added (not just extended), and whether the integration-level Verify for FR-1.3 is better placed in the lifecycle integration test or in a new unit-level test for `GemSyncer#sync`.

---

## Ambiguous Language

### AM-1: "replacing the `list_gems` `NotImplementedError` stub" conflates two different methods

AR-1.1 says to add a presence method "e.g. `has_version?(name, version)` / replacing the `list_gems` `NotImplementedError` stub."
`list_gems` returns a list; `has_version?` checks existence by name+version.
They are not substitutes for each other.
The parenthetical implies `list_gems` would be removed and `has_version?` added in its place, but `list_gems` has its own contract (error message references `gemkeeper list`).
The spec should state explicitly whether `list_gems` is being removed, renamed, or left alone, and where `has_version?` fits in the public interface.

### AM-2: "version line for that exact version" underspecifies the compact-index format

FR-1.2 says the gem is present when "the info document contains a version line for that exact version."
The compact-index `/info` format emitted by `CompactIndex.info(versions)` includes a `---` separator and lines structured as `<version> <platform> <checksum>|<deps>`.
"Version line" is not defined.
The Assumptions & Risks note does say "parsing only the leading version token per line," which is a workable rule, but it belongs in FR-1.2 as a normative requirement, not only as a risk mitigation note.
The spec should state explicitly: skip lines starting with `---` or `created_at:`; split on whitespace; compare the first token against the bare semver.

### AM-3: "present only if the server reports that exact `<name>` and `<version>`" — case sensitivity unspecified

Gem names in the compact-index are case-sensitive by convention, but the spec does not state whether the comparison is case-sensitive.
This matters if a name is stored differently in the manifest vs. what the server indexes.
A one-line clarification ("comparison is case-sensitive, matching the gem name exactly as configured") would prevent a subtle bug.

---

## Codebase Assumptions That May Be Wrong

### CA-1: The `GemUploader` Faraday connection uses `multipart` middleware, which is unnecessary for a plain GET

The existing `connection` method in `GemUploader` builds a Faraday connection with `:multipart` and `:url_encoded` middleware.
Both are only relevant for `POST /upload`.
A `GET /info/<name>` on that same connection is harmless but wasteful (adds a `Content-Type: multipart/form-data` header that is ignored by the server).
The spec should either (a) note this is acceptable and leave it as-is, or (b) instruct the implementer to use a separate plain connection for read-only requests.
Ignoring this risks the presence check failing on edge-case Rack middleware that rejects multipart headers on GETs.

### CA-2: `latest_version!` raises `BuildError`, but the new flow may need a softer return

`latest_version!` in `GemSyncer` raises `BuildError` if `current_version` returns `nil`.
With the new server-check path for `version: latest`, there is a question of whether the existing exception should propagate before or after the server presence check.
The spec does not address what happens if `current_version` returns `nil` and the server already has the gem (build failure, but gem is present — should it be a skip or an error?).

### CA-3: `GemIndex#add` raises `Errno::EEXIST` on conflict — not HTTP 409

AR-1.4 says "an upload that races with an already-present gem (server returns the existing-gem conflict) is treated as success/skip."
`GemUploader#handle_response` already handles 409 as `{ success: true, skipped: true }`, so this is correct at the HTTP layer.
However, the spec says the *presence check* comes before the upload.
After a successful presence check shows the gem is absent, the gem could be uploaded by another process before this process's upload completes — the race actually produces a 409 at upload time, not a "missing" from the presence check.
The spec's idempotency claim in FR-1.4 is correct by accident (existing 409 handling covers it), but the causal chain described is subtly wrong and could confuse an implementer.

---

## Error Handling & Edge Cases

### EH-1: HTTP status codes other than 200, 404 are unspecified for the presence check

AR-1.4 addresses "unreachable or erroring server" and "malformed `/info` response" but not intermediate HTTP errors: 400 (invalid name), 500, 503.
A 503 is the expected response when the gem is absent and the server is offline (see MR-2 above).
A 400 would indicate a bug in name validation, which is a different class of problem.
The spec should enumerate what status codes are treated as "not present" vs. "raise `ServerNotReachableError`" vs. "raise a different error."

### EH-2: Connection failure during presence check timing vs. upload timing

The spec says a connection failure during the presence check raises `ServerNotReachableError`.
But the current `GemSyncer#sync` does no upfront reachability check; it discovers unreachability only when `upload` is called.
With the new flow, the error surface moves earlier (before any git work), which is an improvement.
However, the spec should note whether this earlier detection changes any user-visible behavior (e.g., error message wording, exit code).
Currently `GemUploader#upload` and the proposed `has_version?` would raise the same exception class, but the message may differ.

### EH-3: What if the local artifact is corrupt?

FR-1.3 says when the server is missing the gem and the local `.gem` exists, upload it directly.
The spec does not address what happens if the local artifact is a partial/corrupt file (e.g., interrupted build).
The server's `GemIndex#add` reads the file via `Gem::Package.new(source_path).spec` and will raise `StandardError` on a corrupt gem, which `UploadHandler` likely does not gracefully convert to a 4xx.
The spec should either require a pre-upload integrity check (`Gem::Package.new(path).spec` before upload) or explicitly acknowledge this as out of scope.

---

## Security Concerns

The spec's security review says "N/A beyond existing posture."
This is broadly correct given the loopback-only deployment, but there is one minor gap worth noting:

`GemUploader` currently does not validate the gem name before constructing the `/info/<name>` URL.
On the server side, `VALID_NAME` (line 17 of `compact_index_server.rb`) rejects names that don't match `[a-zA-Z0-9._-]+` and returns 400.
The client should treat a 400 response as a programming error (not a "not present" outcome) rather than silently proceeding.
This is a defense-in-depth note, not a new attack surface, but it is relevant to EH-1 above.

---

## Performance Implications

### PI-1: `version: latest` still always clones/pulls before the skip can fire

For `version: latest`, the server presence check can only fire after `clone_or_pull` and version resolution.
If the intent is fast recovery (re-run sync, get back to work quickly), `version: latest` gems will still incur a network round-trip to the git remote before they are skipped.
The spec acknowledges this implicitly in AR-1.2 but does not flag it as a known cost or consider mitigations (e.g., reading the version from the existing artifact).
This is worth calling out explicitly so the implementer does not optimize away the clone for `latest` and inadvertently break version freshness.

---

## Spec Completeness Checklist — Gaps

| Item | Status | Issue |
| ---- | ------ | ----- |
| Scope & acceptance criteria | Partial | Goals "never re-clones" is untrue for `version: latest` (MR-1) |
| Testing strategy | Partial | `test_gem_syncer.rb` has no `sync()` tests; spec implies extension, not creation (MR-4) |
| Error handling & failure modes | Partial | 503 and other non-200/404 statuses unspecified (MR-2, EH-1) |
| Assumptions & risks | Partial | 503/offline risk for never-uploaded private gems not listed; corrupt artifact not listed |
| Architecture & interfaces | Partial | `build_and_upload` decomposition not specified (MR-3); `list_gems` ambiguity (AM-1) |

---

## Recommended Changes Before Implementation

1. Clarify the `version: latest` goal: either scope "never re-clones" to non-`latest` gems, or add the `Gem::Package` version-read path as an explicit alternative to cloning (MR-1).
2. Add 503 to FR-1.2 as a "not present" signal, or explain why it should be an error (MR-2).
3. Replace the risk-mitigation note about `/info` parsing with a normative parsing rule in FR-1.2 (AM-2).
4. Specify the `build_and_upload` decomposition or name the resulting private methods (MR-3).
5. Clarify whether `list_gems` is removed or retained, and add `has_version?` as a standalone addition (AM-1).
6. Add EH-1's status-code table (200 = check version, 404/503 = not present, others = raise).
