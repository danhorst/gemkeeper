# Spec 20260529-091429: Replace Geminabox with Compact Index Proxy

## Overview

Replace the Geminabox dependency with a minimal custom Rack application (`Gemkeeper::CompactIndexServer`) that serves locally-built private gems via the Bundler compact index protocol and proxies public gem requests to RubyGems.org.
The server also falls back to the system gem cache for offline use when RubyGems.org is unreachable.

## Goals

- Remove the broken Geminabox proxy (uses the retired `bundler.rubygems.org/api/v1/dependencies` endpoint)
- Implement the compact index protocol so Bundler uses efficient, cacheable resolution
- Proxy public gems from RubyGems.org transparently through the same source URL
- Enable offline use by serving from the system gem cache and a local response cache

---

## Feature 1: Compact Index Rack Application

**Who & why:** Developers using gemkeeper configure `source "http://localhost:9292"` as their single Bundler source.
Today that source proxies through Geminabox, whose upstream API was retired in May 2023, producing four retries on every `bundle install`.
They need a server that speaks the compact index protocol Bundler has used since 2016, without that noise.

### Functional Requirements

#### FR-1.1: Core compact index endpoints
The server MUST implement the following endpoints:

- `GET /names` — sorted, newline-delimited list of all gem names (local + proxied upstream), generated per FR-3.5
- `GET /versions` — merged versions index combining private gems and the proxied RubyGems.org versions file, generated per FR-3.1
- `GET /info/:gemname` — per-gem dependency metadata; served from local data for private gems, proxied from RubyGems.org for public gems per FR-3.1
- `GET /gems/:filename.gem` — serve gem binary (local-first, then system cache, then proxy per FR-3.3)

All URL path parameters (`:gemname`, `:filename`) are validated against `/\A[a-zA-Z0-9._-]+\z/` before any filesystem or upstream URL use.
Return 400 for parameters that do not match.
For `GET /gems/:filename`, additionally assert the resolved path is under `gems_path/gems/` before serving.

**Verify:** `bundle install` against a Gemfile backed by this server completes without retries or `HTTPError` output.

#### FR-1.2: Gem upload endpoint
`POST /upload` accepts a multipart form upload with field name `file` (matching the current Geminabox API consumed by `GemUploader`).

Validation: open the uploaded data as a tar archive and confirm it contains `metadata.gz` and `data.tar.gz`.
Extract gemspec metadata from `metadata.gz` using `Gem::Package` inside a rescue block.
Return 422 if the archive is malformed or metadata extraction raises.
Do not `load` or `eval` gemspec content.

On success: create `gems_path/gems/` if absent; write to a temp file in the same directory; rename atomically to `gems_path/gems/<name>-<version>.gem`.
Delete the temp file if validation fails.
Response codes: 201 on success, 409 if the target path already exists, 422 on invalid gem.

After a successful write, rebuild the in-memory gem index per AR-1.1.

**Verify:** `gemkeeper sync` completes successfully; the gem appears in `gems_path/gems/` and in subsequent compact index responses.

#### FR-1.3: Conditional and range request support
All endpoints serving locally-generated or merged content (`/names`, `/versions`, `/info/:gemname`) MUST include:

- `ETag: "<sha256-hex>"` — SHA256 hex digest of the final response body
- `Repr-Digest: sha-256=<base64-encoded-sha256>` — RFC 9530; computed from the same final body
- `Accept-Ranges: bytes`

Do not forward `ETag` or `Repr-Digest` headers from RubyGems.org unchanged for merged responses; recompute from the merged body.

The server MUST handle:
- `If-None-Match` — return 304 if the ETag matches
- `Range: bytes=N-` (open-ended only) — return 206 with the partial body from byte N onward
- `Range: bytes=N-M` or multi-range — return 416

**Verify:** A second `bundle install` produces `304 Not Modified` responses for unchanged index files.

#### FR-1.4: Health endpoint
`GET /` returns `200 OK`.
Used by `ServerReadinessProbe` (`lib/gemkeeper/server_readiness_probe.rb`).

**Verify:** `gemkeeper server start` completes without timing out.

### Architectural Requirements

#### AR-1.1: Atomic in-memory gem index
The server maintains an in-memory gem index (private gem metadata read from `gems_path/gems/`).
After each successful upload, the index is rebuilt into a new object and swapped via a single instance variable assignment.
Index reads do not acquire a lock; the swap is atomic at the Ruby object reference level (copy-on-write).
On startup, create `gems_path/gems/` if absent before scanning.

---

## Feature 2: Private Gem Serving

**Who & why:** The gems built by `gemkeeper sync` must appear in Bundler's dependency graph with correct version and dependency metadata.
Without accurate compact index data for private gems, Bundler will either fail to find them or resolve wrong versions.

### Functional Requirements

#### FR-2.1: Gem file discovery and metadata extraction
On startup and after each successful upload, the server scans `gems_path/gems/*.gem`.
For each file, gemspec metadata is extracted from the embedded `metadata.gz` using `Gem::Package` inside a rescue block.
Files that raise on extraction are skipped with a warning log entry; they do not abort startup.
Extracted metadata: gem name, version, platform, runtime dependencies (name + version constraint), SHA256 checksum of the `.gem` file.

**Verify:** A gem uploaded after server start appears in `/names`, `/versions`, and `/info/:gemname` without restarting the server.

#### FR-2.2: Compact index data generation
Uses the `compact_index` gem to produce correct response bodies.

**`info_checksum` ordering** — info bodies for all private gems must be generated before the `/versions` index is built.
For each private gem, compute `Digest::MD5.hexdigest(CompactIndex.info(gem_versions_array))` and store it as `info_checksum` in the corresponding `CompactIndex::GemVersion`.
The versions index is then built referencing those pre-computed checksums.
Checksums are recomputed after each upload.

**Verified `compact_index` 0.15.0 API:**
- `CompactIndex::GemVersion` — `Struct.new(:number, :platform, :checksum, :info_checksum, :dependencies, :ruby_version, :rubygems_version)`. Field is `number`, not `version`. `checksum` is the SHA256 of the `.gem` file.
- `CompactIndex::Gem` — `Struct.new(:name, :versions)`.
- `CompactIndex::Dependency` — `Struct.new(:gem, :version, :platform, :checksum)`. The dependency gem name is field `:gem`; the constraint string is field `:version`.
- `info_checksum` uses MD5 (not SHA256) per the compact index protocol. Bundler verifies this checksum when it downloads `/info/:gemname`.

**Verify:** `bundle exec gem dependency <private-gem>` resolves correctly when the Gemfile sources from `http://localhost:9292`.

### Architectural Requirements

#### AR-2.1: `compact_index` and `rubygems-generate_index` dependency swap
`gemkeeper.gemspec` drops `geminabox ~> 3.0` and `rubygems-generate_index ~> 1.0`, and adds `compact_index ~> 0.15`.
No other runtime dependencies are added for this feature.

---

## Feature 3: Public Gem Proxy with Offline Cache

**Who & why:** The Gemfile sources all gems — public and private — from `http://localhost:9292`.
Public gem resolution must work when online (proxying to RubyGems.org) and degrade gracefully when offline rather than returning 500 errors.
When offline, gems already installed on the developer's system should be servable directly, avoiding re-download on reconnect.

### Functional Requirements

#### FR-3.1: Merge algorithm for `/versions` and `/info/:gemname`

**`/versions`:**
Fetch `https://rubygems.org/versions` and cache the raw response body to `cache_dir/rubygems_cache/versions` (refreshed when the upstream ETag changes or after 30 minutes).
Construct a `CompactIndex::VersionsFile` from that cached file.
Pass private gem objects as `extra_gems` to `CompactIndex.versions(versions_file, extra_gems)` so they are appended after the upstream public block.
When a private gem name collides with a public gem name, the private gem entry takes precedence: suppress the public entry for that name from the merged output so Bundler cannot resolve the public version.
The public block is never reordered; private entries are appended. This keeps byte offsets of the public block stable across private gem additions, preserving Bundler's incremental range fetching.
Write the merged response to `cache_dir/rubygems_cache/versions.merged` and keep only the merged body's SHA256 hex digest in memory as the current ETag.
Regenerate `versions.merged` on each upload or when the upstream ETag changes.
Serve `/versions` by streaming `versions.merged` from disk; the OS file cache handles hot reads without holding the full body in memory.

**`/info/:gemname` for private gems:** generate from local metadata (FR-2.2).
**`/info/:gemname` for public gems:** proxy `https://rubygems.org/info/:gemname` and cache per FR-3.2.

**Verify:** `bundle install` resolves a public gem (e.g., `rake`) and a private gem through the same local source with no errors.

#### FR-3.2: Cache proxy responses for offline use
Cache proxied compact index responses under `cache_dir/rubygems_cache/`:

- `/versions` raw upstream body: refreshed when upstream ETag changes or after 30 minutes. Use a conditional GET (`If-None-Match`) to upstream; a 304 resets the local TTL without rewriting the file.
- `/info/:gemname` per-gem: cached per gem name; refreshed after 60 minutes using the same conditional GET pattern.
- `.gem` binaries: cached permanently (content-addressed; gem files are immutable once published).

Cache files are written atomically (temp file + rename).

When RubyGems.org is unreachable (connection error or timeout) and a cached copy exists, serve from cache.

**Verify:** After a successful `bundle install` online, disconnecting from the network and running `bundle install` again completes using only cached data.

#### FR-3.3: System gem cache fallback for `.gem` files
Before proxying `GET /gems/:filename.gem` to RubyGems.org, check each path in `Gem.path.map { |p| File.join(p, "cache", filename) }` using `File.exist?` before attempting to read.
If a matching readable file is found, serve it directly without a network request.

**Verify:** A `.gem` file present in the system gem cache is served without an outbound RubyGems.org request.

#### FR-3.4: Response semantics for missing or unreachable upstream
Distinguish three cases for upstream gem requests:

- **Upstream reachable, gem not found** (upstream returns 4xx): return 404 with no body.
- **Upstream unreachable** (connection error, timeout) **+ cache exists**: serve from cache.
- **Upstream unreachable + no cache**: return 503 with body `"Upstream unavailable and no local cache. Connect to the internet and run bundle install to warm the cache."`.

Do not return 500 in any of these cases.

**Verify:** With RubyGems.org blocked and no cache, a request to `/info/nonexistent-gem` returns 503, not 500.

#### FR-3.5: `/names` endpoint
Fetch `https://rubygems.org/names` and cache the raw response body under `cache_dir/rubygems_cache/names` with the same 60-minute TTL and conditional GET refresh as `/info/:gemname`.
Merge local private gem names with the cached upstream names; sort the combined list alphabetically.
Write the merged result to `cache_dir/rubygems_cache/names.merged`; keep only its SHA256 hex digest in memory as the current ETag.
Regenerate `names.merged` on each upload or when the upstream names ETag changes.
Serve `/names` by streaming `names.merged` from disk.

**Verify:** `/names` includes both a known private gem name and a known public gem name.

### Architectural Requirements

#### AR-3.1: HTTP client for proxying
Use `Net::HTTP` (stdlib) for all outbound RubyGems.org requests.
Do not add `faraday`, `httpclient`, or other HTTP client gems for proxy use.

#### AR-3.2: Proxy timeout
Outbound requests use a 5-second open timeout and a 10-second read timeout.
Timeout errors are treated as unreachable (see FR-3.4).

#### AR-3.3: Gem binary streaming
Proxy and cache responses for `.gem` file downloads using bounded buffering or streaming rather than reading the full binary into memory before sending.
RubyGems.org gem files range from a few KB to tens of MB.

---

## Feature 4: Gemkeeper Integration

**Who & why:** The server is an implementation detail inside gemkeeper.
All existing CLI commands, upload flow, list command, server lifecycle, and mirror configuration must continue to work without changes to their respective classes.

### Functional Requirements

#### FR-4.1: config.ru generation
`RackupProcess#config_ru_content` (`lib/gemkeeper/rackup_process.rb`) is updated to generate a config.ru that requires `Gemkeeper::CompactIndexServer` and mounts it, passing `gems_path` and `cache_dir`.
All Geminabox configuration is removed.

**Verify:** The generated `config.ru` contains no references to `Geminabox`; the server starts and responds normally.

#### FR-4.2: Upload API compatibility — no changes to `GemUploader`
`lib/gemkeeper/gem_uploader.rb` is unchanged.
The server's `POST /upload` endpoint accepts the same multipart payload and returns status codes compatible with `GemUploader#handle_response`: 200, 201, or 302 for success; 409 for conflict.
Return 201 for a new upload; 409 if the gem already exists.

**Verify:** `gemkeeper sync` uploads gems without error; a second sync of the same version produces a skip (409 → already-exists path).

#### FR-4.3: List command compatibility — no changes to list
`gemkeeper list` reads `Dir.glob(File.join(gems_path, "gems", "*.gem"))` directly from the filesystem.
The custom server stores uploaded gems at `gems_path/gems/` matching current structure.

**Verify:** `gemkeeper list` output is unchanged after migration.

#### FR-4.4: Server lifecycle — no changes to `ServerManager`, `ServerReadinessProbe`, `BundlerMirrorConfigurator`
These classes are Rack-server-agnostic and require no modifications.

**Verify:** `gemkeeper server start`, `gemkeeper server stop`, and `gemkeeper server status` all behave identically before and after migration.

### Architectural Requirements

#### AR-4.1: New server class location
`Gemkeeper::CompactIndexServer` is implemented in `lib/gemkeeper/compact_index_server.rb` as a Rack application (responds to `call(env)`).
It is instantiated and `run` in the generated `config.ru`.
It is not required anywhere else in the gemkeeper library.

---

## Data Requirements

The `rubygems_cache/` directory layout under `cache_dir`:

```
cache_dir/
  rubygems_cache/
    versions          # raw upstream /versions body
    versions.merged   # merged upstream + private gems (served to Bundler)
    versions.meta     # sidecar: upstream ETag + fetched_at timestamp
    names             # raw upstream /names body
    names.merged      # merged upstream + private gem names (served to Bundler)
    names.meta        # sidecar: upstream ETag + fetched_at timestamp
    info/
      <gemname>       # raw upstream /info/:gemname body
      <gemname>.meta  # sidecar: upstream ETag + fetched_at timestamp
    gems/
      <name>-<version>.gem   # cached gem binaries (permanent)
```

Sidecar `.meta` files are written atomically alongside the body file.

---

## Integration Points

| File | Change |
| ---- | ------ |
| `lib/gemkeeper/rackup_process.rb` | Replace `config_ru_content` |
| `lib/gemkeeper/compact_index_server.rb` | New file — the Rack app |
| `gemkeeper.gemspec` | Remove `geminabox ~> 3.0` and `rubygems-generate_index ~> 1.0`; add `compact_index ~> 0.15` |
| `test/integration/test_server_lifecycle_integration.rb` | Update config.ru content assertions (lines 80–81) |
| `CLAUDE.md` | Update Architecture section; remove Geminabox references |
| `AGENTS.md` | Same updates as CLAUDE.md |

### Known dead code after migration
`GemUploader#list_gems` calls `GET /api/v1/gems.json`, a Geminabox-specific endpoint the new server does not implement.
The method is unused in production (the list CLI reads the filesystem directly).
Remove or raise `NotImplementedError` — do not leave a silently broken public method.

## Related Specs

None — this is a standalone infrastructure replacement.

## Constraints

- No changes to `gem_uploader.rb`, `server_manager.rb`, `server_readiness_probe.rb`, `bundler_mirror_configurator.rb`, or `configuration.rb`
- No new runtime dependencies beyond `compact_index ~> 0.15`
- `POST /upload` multipart API must remain compatible with `GemUploader`
- Gem storage path (`gems_path/gems/*.gem`) must remain unchanged so `gemkeeper list` is unaffected

## Out of Scope

- Authentication for uploads or downloads
- HTTPS/TLS
- Yanking gems
- Proxying sources other than rubygems.org
- The `gemkeeper manifest`, `gemkeeper setup`, or `gemkeeper sync` internals
- Serving legacy index formats (`Marshal.4.8.gz`, `specs.4.8.gz`)
- `GET /api/v1/gems.json` (Geminabox-specific; unused in production after `list_gems` removal)

## Spec Completeness Checklist

- [x] **Scope & acceptance criteria** — each FR has a Verify line; Out of Scope list is explicit; blocking ambiguities from critique resolved
- [x] **Testing strategy** — FRs reference existing tests (FR-4.2, FR-4.4); integration verify conditions cover server start, upload round-trip, offline cache, and Bundler resolution; `test_compact_index_server.rb` implied by AR-4.1 convention (one test file per class)
- [x] **Existing patterns** — references `GemUploader`, `ServerReadinessProbe`, `ServerManager`, `Dir.glob` list pattern, `Gem::Package` extraction, and existing storage path conventions throughout
- [x] **Dependencies** — `compact_index ~> 0.15` justified in AR-2.1; `rubygems-generate_index` removal explicit; `Net::HTTP` (stdlib) chosen in AR-3.1; no other additions
- [x] **Architecture & interfaces** — Rack app interface in AR-4.1; storage layout in Data Requirements; proxy HTTP client in AR-3.1/AR-3.2; config.ru generation in FR-4.1; cache layout in Data Requirements; atomic upload in FR-1.2; atomic index swap in AR-1.1
- [x] **Error handling & failure modes** — FR-3.4 distinguishes upstream 404 vs 503; FR-1.2 covers malformed upload and 422; FR-2.1 covers corrupt gem at startup; AR-1.1 covers concurrent read/write; FR-1.3 covers invalid range (416)
- [x] **Security review** — FR-1.1 adds path parameter validation (`/\A[a-zA-Z0-9._-]+\z/`) and path-under-gems_path assertion; FR-1.2 prohibits gemspec eval; AR-3.1 scopes proxy to rubygems.org only; localhost-only binding inherited from `RackupProcess`
- [x] **Performance impact** — merged `/versions` (~23 MB) and `/names` (~2.7 MB) written to disk and streamed; only SHA256 ETag strings held in memory (FR-3.1, FR-3.5); gem binary proxy streamed per AR-3.3; private gem index is small and negligible
- [x] **Rollout & migration** — drop-in replacement; no data migration; existing `gems_path/gems/` reused; Homebrew formula rebuild required; `list_gems` dead method called out explicitly
- [x] **Assumptions & risks** — `compact_index` 0.15.x field names flagged for pre-implementation verification (FR-2.2); Bundler `Range`/`Repr-Digest` strictness addressed in FR-1.3; `/versions` byte-stability addressed in FR-3.1

---

## Change Log

### Update from `critique-consolidated-v-1.md`

**Applied:**
- B-1: Specified `/versions` merge algorithm — upstream verbatim block first via `VersionsFile`, private gems as `extra_gems`, collision = suppress public entry, byte-stable layout (FR-3.1)
- B-2: Specified ETag and `Repr-Digest` computed from merged body; SHA256 only; no forwarding of upstream headers for merged responses (FR-1.3)
- B-3: Added `info_checksum` generation ordering — info bodies first, checksums embedded before versions index is built (FR-2.2)
- B-4: Added `/names` as a full fetch/cache/merge endpoint matching `/versions` semantics (FR-3.5)
- G-1: Added URL parameter validation (`/\A[a-zA-Z0-9._-]+\z/`) and path-containment assertion to FR-1.1
- G-2: Defined "valid gem" as tar-parseable with extractable metadata; no eval (FR-1.2)
- G-3: Added `mkdir_p`, atomic temp-file write, and temp cleanup to FR-1.2
- G-4: Added AR-1.1 specifying atomic index swap (copy-on-write) for thread safety
- G-5: Replaced FR-3.4 with three-way distinction: upstream 404 → 404; unreachable + cache → serve cache; unreachable + no cache → 503
- G-6: Added `GemUploader#list_gems` dead-method callout to Integration Points; `/api/v1/gems.json` added to Out of Scope
- G-7: Added `rubygems-generate_index` to AR-2.1 as dependency to remove; added to Integration Points table
- Corrected FR-4.2 response codes to match actual `GemUploader#handle_response`: 200/201/302 success, 409 conflict
- Added AR-3.3 requiring gem binary streaming to avoid full-file memory allocation
- Added Data Requirements section with `rubygems_cache/` directory layout and sidecar metadata files
- Added AGENTS.md to Integration Points (both CLAUDE.md and AGENTS.md exist in repo)
- Clarified FR-3.2 cache write atomicity and conditional GET (If-None-Match) refresh behavior

### Pre-implementation compact_index API verification

**Applied:**
- Corrected `info_checksum` hash algorithm from SHA256 to MD5 — the protocol spec and `compact_index` gem both use `Digest::MD5` for this field; Bundler verifies it on download
- Confirmed `GemVersion` field is `number` (not `version`); documented full struct signature
- Confirmed `Dependency` fields: `:gem` for the dep name, `:version` for the constraint
- Confirmed collision suppression works via last-wins semantics — `VersionsFile#contents` appends `extra_gems` verbatim; no pre-filtering of upstream file needed
- Improved FR-3.4 503 body to include actionable guidance for cold-start offline case

**Rejected:**
- "Set Puma thread count to 1" — over-specifies implementation; AR-1.1's atomic swap is the correct architectural constraint
- "Add `test/gemkeeper/test_compact_index_server.rb` as an explicit FR" — the one-test-file-per-class convention is already established in the project; calling it out in the spec over-specifies test structure

**Reorganized:**
- Split old FR-3.1 into FR-3.1 (merge algorithm) and FR-3.5 (/names endpoint) for clarity
- Moved `gems_path/gems/` creation from an implicit assumption into FR-1.2 and AR-1.1 explicitly
- Added Data Requirements section to centralize the cache directory layout (previously scattered across FR-3.1 and FR-3.2)
