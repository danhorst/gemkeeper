# Spec 20260518-154733: Gemkeeper Contractor Support

## Overview
Contractors need to install internal Ruby gems that are normally served from a private gem
server they cannot reach without VPN.
This spec defines the features needed to make gemkeeper a reliable, self-service solution for
this use case: a project setup command, lockfile-aware sync, correct server binding, and
accurate documentation of the full setup sequence.
The companion CLI tool that delivers the gem manifest is specified separately.

## Goals
- Let a contractor configure gemkeeper for a specific project without knowing the internal
  gem inventory
- Make `gemkeeper sync` idempotent against a `Gemfile.lock` with no redundant builds
- Document the end-to-end contractor setup sequence in the gemkeeper README
- Harden the server and sync commands against the most common failure modes

---

## Feature 1: Project Setup Command

**Who & why:** A contractor has just installed gemkeeper and has a `Gemfile.lock` in front
of them.
They should not need to know the names of internal gems, their GitHub URLs, or how to
construct a `gemkeeper.yml` by hand.
`gemkeeper setup` reads the lockfile, cross-references the org gem manifest, and
produces a ready-to-use config.

### Functional Requirements

#### FR-1.1: Setup Command
`gemkeeper setup <path-to-gemfile-lock>` reads the `GEM` section of the lockfile,
cross-references the manifest at `~/.config/gemkeeper/manifest.yml` (override:
`--manifest <path>`), and writes a `gemkeeper.yml` in the current directory.

Each matched gem entry uses `version: "from_lockfile"` so subsequent sync calls read the
current lockfile version rather than requiring setup to be re-run on every lockfile change.

**Behavior when `gemkeeper.yml` already exists:** the command merges — it adds or updates
only entries for gems found in the manifest, leaving all other keys (port, repos_path,
gems_path, unrelated gem entries) untouched.
Pass `--force` to overwrite the file entirely.

**Error cases:**
- Manifest not found at default or `--manifest` path → fail with message directing the user
  to install the org's gem manifest
- Gem appears in lockfile with a name matching an internal pattern but absent from manifest →
  warn and skip, do not fail

**Verify:** Running `gemkeeper setup /path/to/Gemfile.lock` in a directory with no prior
config produces a `gemkeeper.yml` listing only the internal gems the lockfile references, each
with `version: "from_lockfile"`.

#### FR-1.2: Bundler Configuration Output
After setup completes, the command prints the `bundle config` command the developer
must run to redirect their project's internal gem source to the local Geminabox.
If the manifest includes a `source_url` field, that URL is used as the mirror key.
Otherwise, the command prints a generic placeholder the developer must fill in.
Example output:
```
To point Bundler at your local Geminabox, run:
  bundle config set --local mirror.<private-gem-source-url> http://localhost:9292
```
The port in the command matches the configured port in `gemkeeper.yml` (default: 9292).
`git:` source declarations in the Gemfile are unaffected and require no mirror config.

**Verify:** After running the printed command, `bundle install` resolves internal gems from
the local Geminabox and public gems from rubygems.org without modifying any tracked file.

---

## Feature 2: Lockfile-Aware Sync

**Who & why:** With `version: "from_lockfile"` in the config, sync must read the lockfile,
resolve the correct git checkout ref, skip versions already cached, and handle partial
failures gracefully.
A sync that rebuilds everything on every run, or that fails entirely on one bad gem, is not
usable in practice.

### Functional Requirements

#### FR-2.1: `from_lockfile` Version Resolution
When a gem entry specifies `version: "from_lockfile"`, `gemkeeper sync`:
1. Walks up from the current directory to find the nearest `Gemfile.lock`
2. Reads the gem's locked version from the `GEM` section
3. Attempts to check out git tag `v{version}`, then `{version}`, in that order
4. Fails with a named error if neither tag exists in the repo (naming the gem and version)

If no `Gemfile.lock` is found in the directory walk, sync fails with a message naming the
gem and the search path traversed.

`version: "latest"` and explicit version tags continue to work as before.

**Verify:** `gemkeeper sync` for a gem with `version: "from_lockfile"` checks out the git tag
corresponding to the version pinned in the nearest `Gemfile.lock`.
When no lockfile is found, the command exits non-zero with a descriptive message.

#### FR-2.2: Skip Already-Cached Versions
Before cloning, fetching, building, or uploading, `gemkeeper sync` checks whether the `.gem`
file for the resolved version is already present in the Geminabox cache at
`File.join(gems_path, "gems", "#{name}-#{version}.gem")`.
If present, the gem is skipped entirely — no clone, no build, no upload.
Re-running sync with no lockfile change is a no-op.

**Verify:** First sync builds and uploads gem X at version 1.2.3.
Second sync with no lockfile change produces no git, build, or upload activity.
Updating the lockfile to version 1.3.0 causes sync to build and upload only that version.

#### FR-2.3: Partial Failure Handling
If one gem's clone, build, or upload fails, sync continues with the remaining gems.
At the end of the run, sync reports all failures (gem name + error message) and exits
non-zero if any gem failed.
A fully successful sync exits zero.
**Verify:** A sync with one gem that fails to build still attempts all other configured gems
and exits non-zero with a summary of the failure.

#### FR-2.4: Git Authentication Failure Handling
When `git clone` or `git fetch` returns an authentication error, sync exits non-zero with a
message that includes the failed repo URL and a pointer to GitHub credential setup
documentation (`https://docs.github.com/en/authentication`).
The raw git error may be included but the failure type must be identified specifically.
Clone URLs must not use the embedded-token format (`https://token@github.com/...`); the
README must warn against this pattern.
**Verify:** Running sync against a repo with no configured GitHub credentials produces a
message containing "authentication" and the docs URL.

---

## Feature 3: Server and Security Hardening

**Who & why:** Geminabox runs without authentication.
Binding to `0.0.0.0` would expose an unauthenticated gem push endpoint to LAN peers, allowing
a malicious gem to be silently installed by `bundle install`.
Ref validation prevents argument injection from crafted manifest entries.

### Functional Requirements

#### FR-3.1: Localhost-Only Server Binding
`gemkeeper server start` (and `server start --foreground`) must bind Geminabox to `127.0.0.1`
only.
**Verify:** After `gemkeeper server start`, `lsof -i :9292` shows the process bound to
`127.0.0.1`, not `0.0.0.0`.

### Architectural Requirements

#### AR-3.1: `--host 127.0.0.1` Passed to Rackup
The `start_server` and `start_server_foreground` methods in `ServerManager` must pass
`"--host", "127.0.0.1"` in the rackup command array.
This applies to both daemonized and foreground start.

#### AR-3.2: Manifest Ref Validation
Before passing any manifest-derived or lockfile-derived value to `git checkout`, gemkeeper
validates the value against `/\A[a-zA-Z0-9._\-]+\z/`.
Values that do not match are rejected with an error naming the offending entry.
The existing `run_git` method uses `Open3.capture3(*cmd)` array form and is already safe from
shell injection; this validation prevents argument injection (e.g., `--upload-pack=...`).

---

## Feature 4: Documentation

**Who & why:** A contractor following the gemkeeper README must be able to complete setup
independently.
The current README does not document the contractor workflow or the full sequence
of commands needed to get `bundle install` working.

### Functional Requirements

#### FR-4.1: Contractor Setup Sequence
The gemkeeper README must document the full setup sequence as a numbered checklist:
1. Install gemkeeper (`gem install gemkeeper`)
2. Install the org's gem manifest (mechanism provided by the org)
3. Run `gemkeeper setup <path/to/Gemfile.lock>` in the project directory
4. Run `gemkeeper sync` to build and cache internal gems
5. Start the local server (`gemkeeper server start`)
6. Configure Bundler with the command printed by step 3

The checklist must note that GitHub credentials must be configured before step 4 (link to
`https://docs.github.com/en/authentication`).

**Verify:** A new contractor with no prior gemkeeper knowledge can follow the checklist and
reach a passing `bundle install` without assistance.

#### FR-4.2: HTTPS Git URL Documentation
Config examples and the README must document HTTPS GitHub URLs
(`https://github.com/org/repo`) as the recommended format for contractors who have not
configured SSH keys.
SSH URLs (`git@github.com:org/repo.git`) must be noted as an alternative.
**Verify:** The README config examples use HTTPS URLs.

---

## Architectural Requirements (Cross-Cutting)

#### AR-4.1: `from_lockfile` Schema in Configuration
`from_lockfile` is a new reserved string in `Configuration::GemDefinition`, validated
alongside `"latest"`.
The existing `latest?` predicate is joined by a `from_lockfile?` predicate.
`gemkeeper.yml` validation rejects any `version` value that is not `"latest"`,
`"from_lockfile"`, or a string matching `/\A[a-zA-Z0-9._\-]+\z/`.

#### AR-4.2: No Geminabox Patching
All sync logic, idempotency tracking, and version resolution lives in gemkeeper code.
Geminabox is used as a Rack dependency without modification.
`rubygems_proxy = true` is already set in the generated `config.ru` and requires no change.

#### AR-4.3: Bundler Mirror over Source Block
`gemkeeper setup` prints a `bundle config set --local mirror.X Y` instruction rather than
suggesting a Gemfile source block, because the mirror approach requires no change to the
committed `Gemfile` or `Gemfile.lock`.

---

## Integration Points

- gemkeeper setup → `~/.config/gemkeeper/manifest.yml` (written by the org's manifest installer)
- gemkeeper sync → GitHub (HTTPS or SSH clone; no private gem server required)
- gemkeeper server → Geminabox (Rack app, localhost only)
- gemkeeper → Bundler (mirror config, local scope, printed by setup)

## Related Specs

The companion CLI tool that delivers `~/.config/gemkeeper/manifest.yml` is out of scope for this repo.

## Constraints
- Geminabox is used as a dependency, not modified
- Ruby >= 3.1.0 (existing gemspec requirement)

## Out of Scope
- Automating manifest updates on gem release
- Centrally hosted gem mirror
- Windows support
- Gems declared via `git:` source blocks (these already resolve via GitHub; no caching needed)
- CI/CD pipeline support (contractors and local dev only for this spec)

---

## Spec Completeness Checklist

- [x] **Scope & acceptance criteria** — FR-1.1 through FR-4.2 have Verify: lines; Out of
  Scope names exclusions; `git:` source blocks explicitly excluded
- [x] **Testing strategy** — new commands (setup, FR-1.1; manifest-aware sync, FR-2.1–2.4)
  follow the pattern in `test/` with unit tests per class and integration tests for CLI
  commands; manifest loading tested with fixture YAML; lockfile parsing tested with fixture
  lockfiles covering `GEM` and `GIT` sections; FR-3.1 server binding tested via `lsof` in
  integration test; ref validation (AR-3.2) tested with crafted inputs
- [x] **Existing patterns** — spec extends `Configuration::GemDefinition` (AR-4.1),
  `GemBuilder`/`GemUploader`/`GitRepository` (sync FRs), `ServerManager` (FR-3.1);
  `run_git` array form confirmed safe from shell injection
- [x] **Dependencies** — no new runtime gems required; `bundler` gem used for lockfile
  parsing if not already available (it is, as a development dependency); no other additions
- [x] **Architecture & interfaces** — `from_lockfile` schema defined in AR-4.1; lockfile
  search and version-to-tag mapping defined in FR-2.1; idempotency check path defined in
  FR-2.2; server binding defined in AR-3.1; manifest interface defined in Integration Points
- [x] **Error handling & failure modes** — FR-2.1 covers missing lockfile and missing tag;
  FR-2.3 covers partial sync failure; FR-2.4 covers git auth failure; FR-1.1 covers missing
  manifest; AR-3.2 covers invalid refs; known limitation: disk-present ≠ upload-confirmed
  (see Assumptions & Risks #3)
- [x] **Security review** — `run_git` uses `Open3.capture3(*cmd)` array form (safe); AR-3.2
  adds ref validation; AR-3.1 binds to localhost; FR-2.4 prohibits embedded-token URLs;
  no credentials stored by gemkeeper
- [x] **Performance impact** — idempotency check (FR-2.2) skips entire clone/build/upload
  pipeline when version is cached; Geminabox proxies public gems via `rubygems_proxy = true`;
  no production system impact
- [N/A] **Rollout & migration** — additive; existing `gemkeeper.yml` files without
  `from_lockfile` continue to work; server binding change is transparent to users
- [x] **Assumptions & risks** — see below

### Assumptions & Risks

1. **Assumption:** All contractors have HTTPS GitHub access to the internal gem repos listed
   in the manifest.
   The contractor setup checklist (FR-4.1) must state this as a prerequisite.

2. **Assumption:** Internal gem `gemspec` files can be evaluated locally without proprietary
   build tooling.
   If a gem requires a non-standard build step, `gemkeeper sync` will fail.
   Mitigation: verify `gemkeeper sync` succeeds for each gem before adding it to the manifest.

3. **Known limitation:** The idempotency check (FR-2.2) confirms a `.gem` file exists on
   disk, not that it was successfully uploaded to the running Geminabox instance.
   A build whose upload failed will be silently skipped on re-run.
   Mitigation: `gemkeeper list` can be used to verify what the running server holds.

4. **Risk:** Gems containing native extensions produce platform-specific `.gem` files.
   A gem cache is not portable across machines with different CPU architectures.
   Each developer must run `gemkeeper sync` on their own machine.
