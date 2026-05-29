# Critique v1 — Claude
# Spec 20260529-091429: Replace Geminabox with Compact Index Proxy

## Summary

The spec is well-structured and the goal is clear.
The main risks are: the `/versions` merge strategy is underspecified (blocking); ETag generation rules for the merged response are missing (blocking); the upload flow has a gap around gemspec reading after upload; and the offline cache invalidation strategy needs tightening.

---

## Blocking Issues

### 1. `/versions` merge is underspecified — will block implementation

FR-3.1 says private gems "take precedence" on name collision and that the response is "merged."
The `compact_index` gem's `CompactIndex.versions(versions_file, extra_gems)` API expects a `VersionsFile` object managing a cached local file — it is not designed to do a one-shot merge of two remote sources.

Missing:
- How is the RubyGems.org `/versions` file fetched and stored? Is it written to `cache_dir/rubygems_cache/versions`?
- Is the VersionsFile constructed from that cached file, with private gems passed as `extra_gems`?
- What does "take precedence" mean concretely — if `rails` appears in both, does the private entry completely replace all public rails versions, or are the version lists merged?
- The `/versions` file is append-only and chronologically ordered. A "merged" response that re-orders entries by initial release date across two sources is non-trivial. Does the spec require that ordering, or is a simpler concatenation acceptable?

**Recommendation:** Add an AR or explicit note on the merge algorithm: fetch + cache the upstream versions blob, use it as the VersionsFile, inject private gems as extra_gems, let `compact_index` handle the merge. Clarify that "precedence" means the private gem's info checksum wins for any overlapping name, not that public versions are suppressed.

### 2. ETag / `Repr-Digest` generation for the merged `/versions` response

FR-1.3 requires these headers but does not say how they should be computed for the merged response.
The RubyGems.org versions file has its own ETag; after merging with private gems, that ETag is invalid.
If the server forwards the upstream ETag unchanged, Bundler will compute a SHA256 mismatch and retry.

Missing: how the server derives the ETag and `Repr-Digest` for the merged response body.

**Recommendation:** Specify that `ETag` and `Repr-Digest` for `/versions` are computed from the final merged response body (not forwarded from upstream), so Bundler's checksum validation passes.

---

## Significant Gaps

### 3. Gemspec reading after upload — fragility risk

FR-2.1 says the server reads gemspec metadata on startup and "after each successful upload."
But reading dependency metadata from a `.gem` file requires `Gem::Package.new(path).spec`, which loads the full gemspec.
If a gemspec `require`s a file that isn't present in the server's load path (e.g., `require_relative "lib/my_gem/version"`), spec loading will fail silently or raise.

The spec doesn't address this.
Geminabox had the same problem and worked around it by parsing gemspecs in a subprocess.

**Recommendation:** Add an AR specifying how gemspec metadata is extracted — either via `Gem::Package.new(path).spec` with rescue, or by shelling out, or by using only the embedded gemspec without loading it. Note that errors here should produce a 422 response, not a server crash.

### 4. Cache invalidation for `/info/:gemname` — unclear boundary

FR-3.2 says `/info/:gemname` entries are "refreshed after 60 minutes" but the spec doesn't say what triggers a refresh — wall-clock age, an upstream ETag check, or both.

Bundler sends `If-None-Match` with the cached ETag.
If the server forwards that header to RubyGems.org and gets a 304 back, should it reset the 60-minute TTL or not?

**Recommendation:** Clarify: use upstream ETag for conditional GET; if upstream returns 304, update the local TTL; if upstream returns 200, overwrite cache and update TTL.

### 5. Upload directory creation not specified

FR-1.2 says the server saves uploaded gems to `gems_path/gems/`.
But the server is started before any gems are synced — the `gems/` subdirectory may not exist yet.

The spec should explicitly require the server to `mkdir_p gems_path/gems/` on startup (or on first upload).
Currently `RackupProcess#generate_config_ru` creates `gems_path` but not the `gems/` subdirectory.

**Recommendation:** Add to FR-1.2: if `gems_path/gems/` does not exist, create it before writing the uploaded file.

### 6. Path traversal in `/gems/:filename.gem`

FR-1.1 defines `GET /gems/:filename.gem` without addressing input validation.
A filename like `../../etc/passwd` or `../gemkeeper.pid` could escape the `gems_path/gems/` directory.

The spec's security review marks this N/A because the server binds to 127.0.0.1.
That's reasonable for the server-to-client threat model, but the server also passes the filename to the filesystem and potentially to a RubyGems.org URL.
A malformed filename could cause unexpected behavior even from localhost.

**Recommendation:** Add a constraint in AR-4.1 or as an AR under Feature 1: filenames in URL paths are validated to match `/\A[a-zA-Z0-9._-]+-[\d.]+(-[a-z0-9_-]+)?\.gem\z/` before filesystem or proxy operations; return 400 otherwise.

---

## Minor Issues

### 7. `Gem.path` vs `Gem.paths.home` — API clarification

FR-3.3 uses `Gem.path.map { |p| File.join(p, "cache", filename) }`.
`Gem.path` returns an array of gem search paths (GEM_PATH), not just GEM_HOME.
This is correct but worth confirming: on a typical mise-managed setup, `Gem.path` includes both the per-version gem home and any global paths.
The intent (check all system caches) matches the API.
No change needed, but the implementer should be aware that `Gem.path` may include paths without a `cache/` subdirectory — the lookup should use `File.exist?` before serving.

### 8. `gemkeeper list` path discrepancy

The codebase exploration noted that `gemkeeper list` reads `Dir.glob(File.join(gems_path, "gems", "*.gem"))` — meaning it expects gems in a `gems/` subdirectory.
But `gem_syncer.rb` builds gems directly to `gems_path/<name>-<version>.gem` (no subdirectory) before uploading.
After upload, Geminabox stores them in `gems_path/gems/`.

FR-4.3 says the custom server must store uploaded gems at `gems_path/gems/` to preserve this layout.
That's correct, but the spec should also note that `gem_syncer.rb`'s build output path (`gems_path/<name>-<version>.gem`) is a staging location, not a final location — the upload step is what moves it into `gems/`.
This is implicit today; worth making explicit so implementers don't accidentally change the storage layout.

### 9. `compact_index` gem not in Gemfile.lock yet

The spec requires adding `compact_index ~> 0.15` as a runtime dependency.
Worth noting that the Homebrew formula bundles gems and will need to be rebuilt and re-pushed to the tap for the dependency change to take effect in production.
This is already noted in the checklist (Rollout) but not connected to a concrete release step.

### 10. `/versions` response size

RubyGems.org's `/versions` file is currently ~5 MB uncompressed.
Merging it with private gems on every request (even with a 30-minute cache) means the server allocates this in memory for every `/versions` request.
The checklist marks performance as an open item — this is the specific risk to quantify.

---

## Summary of Required Changes

1. **(Blocking)** Specify the `/versions` merge algorithm — VersionsFile from cached upstream + private gems as extra_gems; define "precedence" concretely.
2. **(Blocking)** Specify ETag and `Repr-Digest` computation for merged `/versions` response bodies.
3. Specify gemspec extraction strategy and error handling for FR-2.1.
4. Clarify cache refresh trigger for `/info/:gemname` (wall-clock vs ETag-based).
5. Add `mkdir_p gems_path/gems/` requirement to FR-1.2.
6. Add filename validation constraint for `/gems/:filename.gem` path parameter.
