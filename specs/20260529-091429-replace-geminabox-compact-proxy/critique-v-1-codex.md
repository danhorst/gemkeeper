# Critique v1 - Codex

## Overview

This spec replaces Geminabox with a custom Rack app that serves private gems through Bundler's compact index protocol while proxying RubyGems.org and keeping an offline cache.
The direction is right, but the spec is not implementation-ready yet because the compact index merge rules, cache semantics, and input validation rules are underspecified in places that Bundler will exercise directly.

## Approach Summary

- Add `Gemkeeper::CompactIndexServer` as a Rack app mounted by generated `config.ru`.
- Keep the existing `GemUploader` multipart `/upload` contract and the `gems_path/gems/*.gem` final storage layout.
- Generate private gem compact index data with `compact_index`.
- Proxy RubyGems.org `/names`, `/versions`, `/info/:gemname`, and `/gems/:filename.gem` through `Net::HTTP`.
- Cache upstream compact index files and gem binaries under `cache_dir/rubygems_cache/` for offline fallback.

The replacement choice is well justified by Geminabox's stale dependency endpoint, but the spec currently treats "proxy plus merge" as a simple composition when it is the hardest part of the implementation.

## Risks

### 1. Compact index merge semantics are not concrete enough

Likelihood: high.
Severity: high.
The spec says `/versions` is "merged" and private gems "take precedence", but does not define whether a private/public name collision replaces the entire public name entry, replaces matching versions only, or appends a duplicate line and relies on Bundler parser behavior.
This is also a dependency-confusion risk: if a private gem name exists on RubyGems.org and public versions are still visible, Bundler may resolve a public version.
The local `compact_index` 0.15-compatible API also expects `CompactIndex.versions(versions_file, gems = nil, args = {})`, where `versions_file` is a `CompactIndex::VersionsFile`, not a raw upstream response body.
The spec partially addresses the issue by naming `compact_index`, but it needs an explicit algorithm for `/names`, `/versions`, collision precedence, ordering, and checksum generation.

### 2. Bundler's conditional request contract can fail silently or noisily

Likelihood: medium-high.
Severity: high.
Bundler fetches `names`, `versions`, and `info/*` through the same updater path and uses `Range`, `If-None-Match`, `ETag`, and `Repr-Digest`/`Digest` to update local cache files.
FR-1.3 covers only `/versions` and `/info/:gemname`, leaving `/names` weaker even though RubyGems.org serves `/names` with the same cache headers.
For merged bodies, upstream `ETag` and digest headers are invalid and must be recomputed from the final response body.
The spec does not say what to do with malformed ranges, suffix ranges, range starts beyond EOF, weak ETags, quoted ETags, or `If-None-Match` against a stale upstream cache.

### 3. Offline cache behavior conflates outage, missing gems, and stale data

Likelihood: high.
Severity: medium-high.
FR-3.2 says "non-2xx" means unreachable, but an upstream 404 for `/info/nonexistent-gem` is a valid upstream answer, not an outage.
FR-3.4 then asks for a 404 body saying `"Upstream unavailable and no local cache"`, which is wrong when RubyGems.org is reachable and the gem simply does not exist.
The spec also does not define whether 404s are cached, whether TTL refresh uses wall-clock only or conditional GETs, whether a 304 resets the TTL, or how corrupt/partial cache files are detected and discarded.
Cache writes need to be atomic because Puma can serve concurrent Bundler requests.

### 4. Upload and gem metadata validation are too loose

Likelihood: medium.
Severity: high.
`POST /upload` accepts attacker-controlled multipart data from localhost, and "valid gem" is not defined.
The server should derive name, version, platform, dependencies, required Ruby/RubyGems versions, and checksum from the embedded gemspec in the `.gem`, not from the uploaded filename.
The spec does not require `mkdir_p gems_path/gems`, atomic temp-file writes, duplicate handling by parsed gem identity, filename/spec mismatch rejection, upload size limits, malformed multipart handling, or cleanup after failed validation.
It also says `GemUploader` expects only 201 and 409, but the current code treats 200, 201, 302, and 409 as successful upload outcomes.

### 5. The security checklist is incorrectly marked N/A

Likelihood: high.
Severity: medium.
Binding to `127.0.0.1` reduces exposure but does not eliminate security requirements.
The app accepts URL path input, multipart file input, and emits local gem names and versions.
The spec needs validation for `/info/:gemname` and `/gems/:filename.gem` before filesystem access or upstream URL construction, including path traversal, percent-encoding, absolute paths, control characters, query strings, and overlong names.
Unauthenticated local upload is explicitly out of scope, but the spec should still state the accepted local-only threat model and require defensive input validation.

### 6. Performance impact is larger than the checklist suggests

Likelihood: high.
Severity: medium.
RubyGems.org `/versions` is currently about 23 MB over the wire, and `/names` is about 2.7 MB.
Regenerating a merged body, digest, and ETag for every request will allocate large strings and add latency on a 16 GB workstation.
The spec calls this an open question, but implementation needs a concrete caching strategy for final merged response bodies, invalidation on upload, and upstream refresh cadence.
Gem binary proxying should stream to disk/client or use bounded buffering rather than reading large `.gem` files fully into memory.

## Complexity Hotspots

### Compact index generation and collision rules

This is the core of the feature.
The spec needs to say how private gems become `CompactIndex::Gem` and `CompactIndex::GemVersion` objects, how `info_checksum` is calculated, and how public/private name collisions are represented.
The named API fields are slightly off: the local 0.15-compatible `CompactIndex::GemVersion` struct uses `number`, `platform`, `checksum`, `info_checksum`, `dependencies`, `ruby_version`, and `rubygems_version`, not a `version` field.

### HTTP proxy/cache implementation

The proxy has to combine upstream conditional GETs, local TTLs, offline fallback, final-body digest generation, and Bundler's range update behavior.
This needs a small but explicit cache model: file paths, sidecar metadata, atomic write strategy, status-code handling, and stale-cache rules.

### Upload path and metadata extraction

The server must parse Rack multipart input, validate a gem package, extract metadata, write atomically, and refresh in-memory index state without racing concurrent reads.
The spec gives the happy path but not the failure and concurrency behavior.

### Test harness

The spec relies on "bundle install works" as a verification target, but a lot of failures only show up through exact headers and cache state.
Implementation will need unit tests for route behavior and cache transitions, plus at least one integration test that runs Bundler against the local server with both private and public gems.

## Completeness Checklist Audit

| Item | Status | Notes |
| ---- | ------ | ----- |
| Scope & acceptance criteria | WARN | Each FR has a verify line, but several acceptance criteria are too broad to implement deterministically, especially "merged", "take precedence", "valid gem", and "offline". |
| Testing strategy | WARN | Existing tests are identified, but missing tests for upload success, protocol headers, range edge cases, upstream 404 vs outage, corrupt cache files, path validation, and a real Bundler compact-index install. |
| Existing patterns compared | WARN | The spec references core classes, but misses current `GemUploader#list_gems`, CLI/user-facing Geminabox strings, README/AGENTS updates, `gemkeeper.yml.example`, and the fact that the tracked project doc is `AGENTS.md`, not `CLAUDE.md`. |
| Dependencies justified | WARN | `compact_index ~> 0.15` is a reasonable choice, but the repo already depends directly on `rubygems-generate_index`, which vendors a 0.15-compatible `compact_index`; Gemfile/Gemfile.lock updates and load-order expectations need to be explicit. |
| Architecture & interfaces | WARN | The Rack entry point and storage layout are named, but route validation, cache object boundaries, response header helpers, concurrency strategy, and generated `config.ru` require path are not fully specified. |
| Error handling & failure modes | FAIL | Upstream 404s, malformed ranges, invalid multipart bodies, invalid gem packages, partial downloads, corrupt cache files, filesystem write failures, and cache races are not adequately covered. |
| Security review | FAIL | Marking security N/A is not adequate because the server accepts path parameters and file uploads and proxies requests based on user-controlled values. |
| Performance impact | FAIL | The checklist honestly leaves this open, but `/versions` size and per-request merge/digest cost are large enough that the spec needs a concrete design before implementation. |
| Rollout & migration | WARN | Data migration is probably unnecessary, but the "drop-in" claim omits user-facing renames, docs updates, Gemfile.lock, Homebrew release steps, and whether compatibility endpoints like `/api/v1/gems.json` remain. |
| Assumptions & risks | WARN | The spec names the strict Bundler cache risk, but understates compact-index API details, public/private name collision behavior, and the incorrect `CLAUDE.md` integration point. |

## Verdict

NEEDS WORK.
The goal and high-level architecture are solid, but implementation would force too many protocol, cache, security, and migration decisions in code.
Those decisions affect correctness under Bundler, so they should be settled in the spec first.

## Suggested Next Steps

1. Define the exact `/names` and `/versions` merge algorithm, including private/public name collision semantics and dependency-confusion behavior.
2. Specify how `ETag`, `Repr-Digest`, `Digest`, `Accept-Ranges`, 206, 304, and invalid range responses are generated for all compact index endpoints, including `/names`.
3. Define the proxy cache layout and rules for TTL, conditional upstream refresh, upstream 404 vs outage, corrupt cache recovery, atomic writes, and stale fallback.
4. Add explicit validation requirements for gem names, gem filenames, upload files, parsed gemspec identity, and filesystem path construction.
5. Correct codebase assumptions: use `AGENTS.md` instead of `CLAUDE.md`, decide whether `/api/v1/gems.json` is still supported for `GemUploader#list_gems`, and include README/CLI/example config wording if Geminabox is truly replaced.
6. Expand tests to cover compact-index route units, upload success/failure, offline cache transitions, malicious paths, and a Bundler integration install with one private gem and one public gem.
