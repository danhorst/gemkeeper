# Critique (v1) — Claude

Spec: Server-authoritative sync cache check (`20260529-131354`)

## Summary

The spec correctly diagnoses the root cause and picks the right core fix (server-authoritative skip via the existing `/info` endpoint, with artifact re-upload to avoid rebuilds). Scope is well-bounded and the deployment-mode constraint (AR-1.3) is the key insight that keeps the design honest. Below are gaps that would cause an implementer to stop and ask, plus a few correctness traps in the actual `/info` and upload mechanics.

## Blocking / should-fix

### 1. `/info` presence parsing is under-specified against the real format (FR-1.2)
The compact-index info document produced by `CompactIndex.info` is **not** a flat list of versions. Each line is roughly `VERSION DEP:REQ,...|checksum:...,ruby:...`, and the document begins with a `---` header line. FR-1.2 says "contains a version line for that exact version," but doesn't pin down:
- That the match must be on the **first whitespace-delimited token** of a line, anchored, not a substring (`1.0.5` must not match `1.0.50` or a checksum that happens to contain `1.0.5`).
- That the leading `---` and any blank lines are ignored.
- **Platform variants:** a gem can have multiple lines for the same version with different platforms (e.g. `1.0.5` and `1.0.5-x86_64-darwin`). The spec treats presence as `(name, version)` only. If a platformed gem is involved, "version present" may be true while the *specific artifact filename* `<name>-<version>-<platform>.gem` is still missing from the server. Either declare platforms out of scope explicitly, or check the artifact filename, not just the version token.

Recommend FR-1.2 specify anchored first-token matching and state the platform assumption (private gems are pure-Ruby → filename is `<name>-<version>.gem`); if that assumption holds it should be written down, because `SpecMapper.filename` already branches on platform.

### 2. Presence-vs-served gap: `/info` is built from `GemIndex`, but is it the same store the binary is served from? (FR-1.1/FR-1.2)
The skip decision trusts `/info` to mean "the server can serve `/gems/<file>`." In the current server, `serve_info` reads `@index[gemname]` (from `GemIndex`, i.e. `gems_path/gems`) and `serve_gem_file` reads `@index.gem_path || @cache.gem_binary`. These share `@index`, so they should agree — but the spec should state this invariant explicitly as the thing it depends on: **a version appearing in `/info` implies `/gems/<file>` is serveable from the private store.** If that ever stops holding (e.g. `/info` proxied upstream), the skip becomes wrong. Worth an AR pinning "presence is determined only from the private index, never an upstream-proxied `/info`." Note `serve_info` falls back to `@cache.info(gemname)` (upstream) when the gem isn't private — for a private gem name that the server doesn't have, `/info` would proxy to rubygems.org, 404, and return not-found, which is fine; but a name collision with a public gem could make `/info` return a *public* document and produce a false "present." This edge (private gem sharing a name with a public gem) should be acknowledged.

### 3. "Existing local artifact" lookup location is ambiguous (FR-1.3, AR-1.2)
FR-1.3 says re-upload when "the corresponding `.gem` already exists in the local `gems_path`." But `cached?` today checks `gems_path/<name>-<bare>.gem` (flat) while the server store is `gems_path/gems/`. The spec should state unambiguously that the artifact lookup is the **flat build-output location** (`gems_path/<name>-<version>.gem`, where `GemBuilder` writes), to avoid an implementer re-introducing the same flat-vs-nested confusion the spec is trying to fix. Tie it to `SpecMapper.filename`/the bare-semver key so the filename is derived one way.

### 4. `version: latest` interaction needs the ordering spelled out (AR-1.2)
For `latest`, the version isn't known until after clone+checkout (`current_version` post-checkout). So the "ask server first, skip without building" optimization **cannot apply to `latest`** — you must fetch the repo to learn the version before you can query `/info`. The spec acknowledges ordering in AR-1.2 but doesn't state the consequence: `latest` gems always incur a fetch (today they do too — `cached?` is bypassed for `latest` via `!gem_def.latest?` in `sync`). Make explicit that `latest` keeps today's behavior (always fetch, then the server check applies to the resolved version for the *upload/skip* decision), so the skip optimization is for pinned versions only.

## Edge cases / smaller

- **FR-1.4 conflict handling:** `UploadHandler` maps `Errno::EEXIST` → `409 "Gem already exists"`. `GemUploader#handle_response` currently treats `409` as `{ success: true, skipped: true }`. Good — the spec's "treat conflict as skip" already matches code, but FR-1.4 should cite the 409 path so the implementer doesn't change it.
- **Counting/reporting (FR-1.5):** the `sync` command tallies `:synced`/`:skipped` from `GemSyncer#sync`'s return symbol. Adding a third outcome (artifact re-upload) — is it `:synced` or a new symbol? `report_results` only knows two. Decide whether re-upload counts as `:synced` (simplest, keeps the tally) with differentiated *output text*, or a new `:uploaded` symbol (touches `run_sync`/`report_results`). The spec implies differentiated messaging but not the symbol contract.
- **Idempotency race (FR-1.4):** "upload that races with an already-present gem" — concurrency isn't really present (sync is sequential), so this is just the 409 path. Reword to avoid implying real concurrency handling is required.
- **Malformed `/info` → not-present (AR-1.4):** treating malformed as not-present means a flaky/garbage response triggers an upload attempt, which then 409s or 201s harmlessly. That's a safe failure direction; worth stating that "not-present on parse failure" is deliberately biased toward re-uploading rather than skipping.
- **`reachable?` already exists** on `GemUploader` but `sync` doesn't currently call it; the new presence call effectively becomes the reachability probe. Consider whether the first presence call should produce the not-reachable error early (per-gem vs once up front).

## Testing

- The spec leans on stubbing `/info`. `test_gem_uploader.rb` likely already stubs Faraday — confirm the presence method is testable the same way (it is, if it's on `GemUploader`).
- Add an integration test that reproduces the original bug: build artifact present, fresh/empty server, `sync` → server serves the gem afterward. This is the regression guard and should be called out as required, not optional.

## Checklist assessment

Honest and well-evidenced. Security N/A is justified (loopback, `VALID_NAME`, read-only `/info`) — but the **private-name-collides-with-public-gem** false-positive (point 2) is a small correctness/security-adjacent edge the checklist's security note should acknowledge. Performance and rollout are appropriately sized.

## Verdict

Sound design, right scope. Resolve the `/info` parsing precision + platform assumption (1), the presence-implies-serveable invariant incl. public-name-collision (2), the artifact-location wording (3), and the `latest` ordering consequence (4) before implementing. The rest are wording tightenings.
