# Critique: Replace Geminabox with Compact Index Proxy

Reviewed by: GitHub Copilot (claude-sonnet-4.6)
Date: 2026-05-29

## Summary

The spec is well-scoped and the integration points are clearly identified.
The constraints table and out-of-scope list are unusually precise — useful.
However, several correctness traps exist that would produce a server that passes basic smoke tests but fails under Bundler's actual caching behaviour.
The most serious issues are the `/versions` byte-stability problem (correctness), the missing thread-safety requirement (reliability), and the unspecified `/names` scope (ambiguity with large performance consequences).
The testing section is thin for the volume of new logic being introduced.

---

## 1. Critical: Correctness Blockers

### 1.1 `/versions` byte-stability is unaddressed, and merging breaks Bundler's range fetching

FR-1.3 requires the server to support `Range: bytes=N-` to serve partial `/versions` responses.
This is how Bundler efficiently updates its local copy: it records the file size it last fetched, then asks for only the bytes after that offset.

The spec's merge strategy (FR-3.1: "private gem entries take precedence when a name appears in both") sorts or interleaves private gems into the rubygems.org `/versions` body.
Any time a new private gem is added, the byte offsets of every subsequent line in the merged file shift.
Bundler's cached offset is now wrong: the range request returns garbled data, and Bundler either fails or silently resolves wrong versions.

The spec does not define a stable layout for the merged `/versions` output.
Options include appending private gems after the public block, or rebuilding the rubygems.org block verbatim and appending private entries — but the spec is silent.
Without a stable layout rule, this is a correctness defect, not just a performance issue.

### 1.2 `info_checksum` has a circular dependency

FR-2.2 requires `CompactIndex::GemVersion` to carry an `info_checksum` field.
That checksum is the SHA256 of the `/info/:gemname` response body.
To populate it in the `/versions` entry, the server must generate the `/info` body first, hash it, and embed the hash in `/versions`.

The spec never describes this ordering, nor does it mention that the `info_checksum` must be recomputed whenever a new version of a gem is uploaded (because the `/info` body changes).
An implementer who builds the versions index first and the info body second will produce invalid checksums that cause Bundler to re-fetch unconditionally.

### 1.3 `/names` scope is undefined and carries large performance risk

FR-1.1 says `/names` returns "all gem names (local and proxied)."
The rubygems.org `/names` file currently contains ~175,000 gem names (roughly 2 MB uncompressed).
"Proxied" in this context almost certainly means the full public gem namespace.

The spec never says whether the server fetches, caches, and merges the rubygems.org `/names` file (like it does for `/versions`), or whether `/names` is scoped only to gems that have been locally requested or cached.
These produce completely different behaviour:
- Full public namespace: bundle install resolves public gems by name — correct, but the endpoint becomes expensive.
- Local-only: bundle install fails on any public gem not already in the info cache.

The performance checklist item (unchecked) notes only the `/versions` merge cost; it does not mention `/names`.
This is a missing requirement.

---

## 2. Ambiguous Requirements

### 2.1 "Valid gem" definition in FR-1.2

FR-1.2 returns 422 "if the file is not a valid gem" but does not define valid.
Three plausible interpretations:

1. File extension is `.gem`
2. File is a parseable tar archive containing `metadata.gz` and `data.tar.gz`
3. The gemspec within `metadata.gz` can be loaded without error

These have substantially different implementation and security implications.
Option 1 is trivially bypassable.
Option 3 can raise arbitrary Ruby exceptions if the gemspec calls `require`.
The spec should specify what validation is expected — likely option 2 at minimum.

### 2.2 `/versions` cache stores raw upstream or merged output?

FR-3.2 says cache the `/versions` response.
It is ambiguous whether the cache stores:

- The raw rubygems.org response (requiring re-merge with private gems on every request), or
- The merged result (requiring cache invalidation on every gem upload)

Both are valid designs; they have different invalidation logic.
The spec does not specify which, leaving the implementer to decide and potentially choosing the one that breaks ETag/Range behaviour.

### 2.3 ETag algorithm: "MD5 or SHA256"

FR-1.3 says use "MD5 or SHA256" for the ETag.
Giving two options creates inconsistency risk — different code paths might use different algorithms, making ETags non-comparable across restarts.
Pick one.
SHA256 is the better choice (used for `Repr-Digest` too; re-using the same hash avoids a second pass).

### 2.4 `handle_response` in `GemUploader` accepts 200 and 302, not just 201

FR-4.2 states that the new server must return "the same status codes (201, 409) that `GemUploader` expects."
This is inaccurate.
`GemUploader#handle_response` maps `200`, `201`, and `302` as success.
The spec's description of `GemUploader`'s contract is wrong.
While the new server returning 201 will still work (201 is handled), a future implementer auditing the spec against the code will find the discrepancy and may add unnecessary 302 handling or question the spec's accuracy.

---

## 3. Codebase Assumption Gaps

### 3.1 `GemUploader#list_gems` calls `/api/v1/gems.json`

The spec says "no changes to `GemUploader`" and it is correct that `list_gems` is never called from any production code path (the `list` CLI reads the filesystem directly via `Dir.glob`, per FR-4.3).
But `list_gems` is a public method that calls `GET /api/v1/gems.json`, a Geminabox-specific endpoint.
After this migration, calling `list_gems` will return a 404.

The spec should either note that `list_gems` becomes a dead method (and optionally raise `NotImplementedError`), or explicitly call out this known breakage so the implementer doesn't silently leave a broken public method.

### 3.2 `rubygems-generate_index` dependency is not addressed

The gemspec currently declares `rubygems-generate_index ~> 1.0`.
This gem exists to support Geminabox's legacy Marshal index generation (`specs.4.8.gz`, `Marshal.4.8.gz`).
The spec removes Geminabox and explicitly excludes legacy index formats from scope, but says only to swap `geminabox` for `compact_index` in the gemspec.
`rubygems-generate_index` is likely now unused dead weight.
Whether to remove it is a judgment call, but the spec should at least acknowledge it.

### 3.3 Integration test has more Geminabox assertions than lines 80–81

The Integration Points table says to update lines 80–81 of `test_server_lifecycle_integration.rb`.
In the current file, there are two assertions that reference Geminabox:

```ruby
assert_match(/Geminabox\.data/, content)               # line 80
assert_match(/Geminabox\.rubygems_proxy\s*=\s*true/, content)  # line 81
```

But the test method is named `test_server_generates_config_ru`, and the test class also has `test_server_status_while_running` which checks `status[:url]` equals `@config.geminabox_url`.
The `geminabox_url` method name on `Configuration` is referenced both here and in `RackupProcess#wait_for_server`.
The spec is silent on this naming — the constraint says "no changes to `configuration.rb`", so the stale method name remains.
The integration test assertion on `geminabox_url` will still pass (the URL format doesn't change), but it should be called out in the spec as an accepted naming inconsistency rather than left for the implementer to discover.

### 3.4 `compact_index` gem API is assumed but not verified

The spec builds on `CompactIndex::GemVersion`, `CompactIndex::Dependency`, `CompactIndex.names()`, and `CompactIndex.info()`.
The spec's own checklist flags this: "key assumption: `compact_index` 0.15.x API is stable."
The `compact_index` gem is primarily an internal RubyGems.org dependency.
Its README is sparse and its public API is not documented for external consumers.
Before implementation begins, the actual gem should be inspected to confirm the class names and method signatures match what the spec assumes.
This is flagged here not as a spec defect, but as a pre-implementation step that is conspicuously absent from the spec.

---

## 4. Error Handling and Edge Case Gaps

### 4.1 Thread safety for the in-memory gem index

FR-2.1 says the server rescans `gems_path/gems/*.gem` after each successful upload.
Puma (the configured server) uses a thread pool by default.
A concurrent GET `/info/:gemname` while an upload is updating the in-memory index will produce a data race.

The spec does not require synchronization (a `Mutex` around index reads and writes, or a copy-on-write swap).
In practice, Ruby's GVL limits the impact, but it is not zero — especially during index rebuild where multiple instance variables are updated in sequence.
The spec should specify that the gem index is updated atomically (e.g., replace the entire index object with a new one via a single assignment).

### 4.2 Range request with explicit end byte is unspecified

FR-1.3 says handle `Range: bytes=N-` (open-ended).
The HTTP spec also allows `Range: bytes=N-M` (explicit end) and multi-range requests (`Range: bytes=0-99, 200-299`).
Bundler currently only sends open-ended ranges, but the spec should be explicit that multi-range and bounded-range requests return 416 (`Range Not Satisfiable`) or fall back to the full response, rather than leaving this undefined.

### 4.3 Behaviour when `gems_path/gems/` contains a corrupt `.gem` file

FR-2.1 scans all `.gem` files on startup and on upload.
If a file is corrupt (truncated download, disk error), extracting gemspec metadata will raise an exception.
The spec does not say whether the server should skip corrupt files with a warning or abort startup.
If startup is aborted, a single bad file makes the server unlaunchable.

### 4.4 Concurrent upload of the same gem

FR-1.2 returns 409 if the file already exists.
If two `gemkeeper sync` processes run simultaneously and both upload the same gem at the same time, a TOCTOU race exists between the existence check and the file write.
The spec should specify last-write-wins, or require a file lock.

### 4.5 System gem cache traversal under `Gem.path`

FR-3.3 checks `Gem.path.map { |p| File.join(p, "cache", filename) }`.
`Gem.path` includes user-defined paths from `GEM_PATH` environment variable.
A developer with a misconfigured `GEM_PATH` pointing to a path they don't own could cause unexpected file-serving behaviour.
This is a minor concern given localhost-only binding, but the spec should note that only paths where the file is readable are considered.

---

## 5. Security Concerns

### 5.1 Path traversal in `/gems/:filename.gem`

FR-3.3 constructs a filesystem path from the URL parameter `filename`.
A request to `/gems/../../../../etc/passwd` (URL-decoded by Rack before routing) would traverse outside `gems_path`.
Even on localhost, any process on the same machine can make this request.

The spec's security checklist dismisses auth and input validation as out of scope because the server "binds to 127.0.0.1 only."
That reasoning does not cover path traversal — localhost binding doesn't prevent local processes from exploiting it.
The spec should require that `filename` be validated to contain only safe characters (`[a-zA-Z0-9._-]`) or that the resolved path is asserted to be under `gems_path` before serving.

### 5.2 SSRF via cached rubygems.org requests

The server makes outbound requests to `https://rubygems.org/info/:gemname` where `gemname` comes from the incoming request URL.
A local process could request `/info/../../../../etc/passwd` — the gemname would be used to construct the upstream URL `https://rubygems.org/info/../../../../etc/passwd`.
While rubygems.org would return a 404, the spec should require URL-encoding or validation of `:gemname` before constructing the upstream URL.

---

## 6. Performance Concerns

### 6.1 In-memory merge of `/versions` on each request (already flagged in checklist)

The spec acknowledges this is an open question.
A concrete recommendation: cache the fully merged `/versions` body in memory and invalidate it only when a gem is uploaded (cheap) or when the upstream ETag changes (already covered by FR-3.2).
The spec should promote this from "open question" to a requirement: "merged `/versions` response is memoized in memory; invalidated on upload or upstream ETag change."

### 6.2 Full gem metadata re-scan on every upload

FR-2.1 says "scans `gems_path/gems/*.gem`" after each upload.
For a large private gem store, this O(n) re-scan on every upload is unnecessary.
An incremental approach (add the newly uploaded gem to the in-memory index directly) would be more efficient.
This is a recommendation rather than a blocker, but if left as a full re-scan, the spec should cap the acceptable gem count or note the known performance characteristic.

---

## 7. Testing Strategy Gaps

### 7.1 No unit tests specified for `CompactIndexServer`

The spec introduces a new 200+ line Rack application implementing 8 endpoints, proxy logic, cache management, and ETag/Range support.
The testing section mentions only one integration test update (lines 80–81) and four "Verify" lines that describe manual/integration scenarios.

There are no unit tests specified for:
- Correct `ETag` and `Repr-Digest` header generation
- 304 response when ETag matches
- 206 response for range requests
- The merge logic for `/versions`
- Corrupt gem handling (FR-4.3 gap above)
- Offline fallback path (FR-3.4)

Given the project's existing unit test pattern (one `test_*.rb` per class), `test/gemkeeper/test_compact_index_server.rb` should be called out explicitly, even if only to anchor a few key behaviours.

### 7.2 FR-4.2 verify claim is overconfident

FR-4.2 says "the existing `test/gemkeeper/test_gem_uploader.rb` passes without modification."
The existing tests only test connection failure paths (no live server involved).
They do not test a successful upload against a real or mock server.
The claim that the tests "pass without modification" is true today, but it does not verify that the upload flow actually works against the new server.
A new integration test covering the upload round-trip should be called out here.

---

## 8. Spec Completeness Checklist Assessment

| Item | Assessment |
| ---- | ---------- |
| Scope & acceptance criteria | ✅ Clear. Out of Scope list is precise and useful. |
| Testing strategy | ⚠️ Thin. No unit tests for the new Rack app; FR-4.2 verify is misleading. |
| Existing patterns | ✅ Correctly identifies `GemUploader`, `Dir.glob` list pattern, `ServerReadinessProbe`. |
| Dependencies | ⚠️ `rubygems-generate_index` not addressed; `faraday`/`faraday-multipart` not mentioned as retained. |
| Architecture & interfaces | ✅ Rack app interface, config.ru, storage layout clearly specified. |
| Error handling & failure modes | ⚠️ Corrupt gem files, TOCTOU on upload, thread safety, and range-end handling are missing. |
| Security review | ❌ Path traversal in filename parameter and SSRF in gemname-to-upstream-URL construction are unaddressed. The localhost-only justification does not cover these. |
| Performance impact | ⚠️ Acknowledged as open question but not resolved. `/names` scope is a larger risk than the spec recognises. |
| Rollout & migration | ✅ Drop-in; no data migration; Homebrew rebuild noted. |
| Assumptions & risks | ⚠️ `compact_index` API stability flagged but no pre-implementation verification step prescribed. |
