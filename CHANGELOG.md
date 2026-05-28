## [Unreleased]

## [0.7.2] - 2026-05-28

### Fixed

- `sync` now correctly skips gems that are already cached locally.
  The cache check was looking in `gems_path/gems/name-version.gem` but `gem build` saves to `gems_path/name-version.gem`, so every gem was rebuilt and re-uploaded on every run.
- `sync` no longer checks out the trunk branch twice for `version: latest` gems.
  `fetch_repo` already leaves the repo on trunk after clone or pull; the redundant `checkout_version("latest")` call is removed, and the cache check now happens immediately after fetch.

## [0.7.1] - 2026-05-28

### Fixed

- `gemkeeper setup` no longer duplicates entries when an existing `gemkeeper.yml` has `repo:`-only entries (no `name:`) whose URL basename differs from the manifest gem name.
  The merge now resolves those entries by repo URL against the manifest to find the canonical name, then replaces the old entry in place rather than keeping it and appending a new one.

## [0.7.0] - 2026-05-28

### Changed

- `gemkeeper setup` and `gemkeeper manifest generate` no longer write `repo:` into generated `gemkeeper.yml` entries.
  The repo URL is resolved from the manifest by gem name at sync time, making the manifest the single source of truth for name→repo mappings.
  Re-running `setup` strips `repo:` from matched entries, promoting them to manifest-only.
- `gemkeeper setup` now accepts only a `Gemfile.lock`, `Gemfile`, or directory as its source.
  The path that imported an existing `gemkeeper.yml` into the manifest has been removed — it only made sense when configs carried `repo:`; populate the manifest with `gemkeeper manifest generate` or `setup` from a lockfile instead.

### Added

- `repo:` in `gemkeeper.yml` is now optional. When absent, `gemkeeper sync` resolves it from the manifest (`~/.config/gemkeeper/manifest.yml`) by gem name.
  It remains a supported per-project override (escape hatch) for gems not in the manifest; `sync` warns when an explicit `repo:` diverges from the manifest and uses the `gemkeeper.yml` value.

## [0.6.7] - 2026-05-28

### Fixed

- `gemkeeper setup` and `gemkeeper manifest generate` now write an explicit `name:` field for every gem entry in `gemkeeper.yml`.
  Previously the gem name was always derived from the repo URL at runtime, which breaks when the repo is renamed and no longer matches the gem name.
- Re-running setup after a repo rename now correctly updates the entry: the existing entry is matched by its explicit `name:` field rather than by the repo URL basename, and the `repo:` URL is updated to the current value from the manifest.

## [0.6.6] - 2026-05-28

### Fixed

- Gem uploads and server request handling now work correctly on Ruby 4.0 / RubyGems 4.0.
  rack 2.x is incompatible with Ruby 4.0; upgraded to geminabox 3.0 which pulls in sinatra 4 and rack 3.
  Added `rackup` as an explicit dependency — rack 3.x extracted the `rackup` executable into its own gem.

## [0.6.5] - 2026-05-28

### Fixed

- `gemkeeper server status` now correctly detects a running server even when no PID file exists (e.g., when started via `brew services start`).
  Previously, status relied solely on a PID file that foreground mode never writes.
  It now falls back to a TCP port check, and the PID line is omitted from the output when the process is not managed directly by gemkeeper.
- `gemkeeper server stop` now gives a clear error when the server is running but not managed by gemkeeper (no PID file), directing the user to `brew services stop gemkeeper` instead of failing silently.

## [0.6.4] - 2026-05-28

### Fixed

- `gemkeeper server start --foreground` now exits non-zero when rackup fails (e.g., port already in use).
  Previously a rackup crash returned exit 0, causing launchd to respawn immediately in a tight loop with no visible error.
  The failure reason is now logged and the process exits 1, giving launchd an accurate status and making the cause diagnosable via `brew services info`.

## [0.6.3] - 2026-05-28

### Fixed

- The Geminabox server now starts correctly on Ruby 3.3+ (including the Homebrew-installed Ruby 4.x).
  `rubygems/indexer` was extracted from RubyGems in 3.3 into the `rubygems-generate_index` gem;
  the generated `config.ru` was requiring it directly before geminabox could apply its own fallback.
  Removed the redundant require and added `rubygems-generate_index` as an explicit dependency.

## [0.6.2] - 2026-05-28

### Fixed

- `gemkeeper server start --foreground` now works correctly when run as a Homebrew service (via `brew services start`).
  launchd runs with a minimal PATH that does not include the gem's `bin/` directory, so `rackup` was silently not found and the server exited 0 on every launch attempt.
  The server now resolves `rackup` from `GEM_HOME/bin` when available, matching the path set by the Homebrew bin wrapper.

## [0.6.1] - 2026-05-28

### Fixed

- `gemkeeper sync` now exits immediately with a clear, actionable error message when the Geminabox server is not reachable, instead of failing once per gem with a raw connection error.

## [0.6.0] - 2026-05-28

### Added

- `gemkeeper setup` now accepts a directory path and finds `Gemfile.lock` inside it.
- `gemkeeper setup` now accepts a `Gemfile` path and uses the sibling `Gemfile.lock`.
- `gemkeeper setup` now works with no arguments by finding the nearest `Gemfile.lock` (walks up from the current directory).
- `gemkeeper manifest generate` now accepts a directory, `Gemfile` path, or no arguments (same resolution as `setup`).

### Fixed

- `gemkeeper setup` no longer configures a Bundler mirror for a private gem registry when all gems from that source were skipped during manifest resolution.
- `gemkeeper setup` and `gemkeeper manifest generate` now report a clear error when the resolved source path does not exist.
- All commands that accept `--config` now report a clear error when the specified config file does not exist, instead of silently using defaults.
- `gemkeeper server stop` now exits 0 when the server is already stopped; stopping an already-stopped server is not an error.

## [0.5.0] - 2026-05-27

### Added

- `gemkeeper manifest generate LOCKFILE_PATH` builds or updates the gem manifest from a Gemfile.lock.
  Merges with any existing manifest by default; `--force` overwrites it entirely.
  Accepts `--manifest` to specify a non-default path.
- `gemkeeper manifest validate [PATH]` checks a manifest file for structural errors: missing fields, invalid repo URLs, duplicate names, and malformed `source_url`.
  `--resolve` additionally probes each repo with `git ls-remote` (5s timeout per entry) to verify reachability.
- During interactive `gemkeeper setup`, gems with inaccessible source repos can now be skipped.
  Enter nothing when no URL can be inferred, or type `skip` at any prompt.

## [0.4.0] - 2026-05-27

### Added

- `gemkeeper setup` no longer requires a pre-existing manifest.
  When given a Gemfile.lock, it discovers internal gems by source type and builds or updates `~/.config/gemkeeper/manifest.yml` automatically.
  GIT-sourced gems (declared with `git:` in the Gemfile) are added directly — the repo URL comes from the lockfile.
  Gems from private registries (e.g. GitHub Packages) have their repo URL inferred where possible or prompted for interactively; running non-interactively without a resolvable URL exits with a clear error.
- `gemkeeper setup` accepts either a Gemfile.lock or an existing `gemkeeper.yml` as its argument.
  Passing a `gemkeeper.yml` updates the manifest with its repo mappings and, with `--global`, installs it to the global config path.
- The `--manifest` option controls the path used for both reading and writing the manifest, defaulting to `~/.config/gemkeeper/manifest.yml`.
- `gemkeeper setup` now automatically configures Bundler mirror settings for each private gem registry found in the lockfile, pointing them at the local Geminabox.
  Uses `--local` scope by default; `--global` setup uses `--global` scope.
  Pass `--skip-bundler-config` to opt out.

### Fixed

- GIT-sourced gems (pinned in the `GIT` section of the lockfile) are now included in the generated `gemkeeper.yml`.
  Previously they were silently omitted because the lockfile parser only read `GEM` sections.

## [0.3.0] - 2026-05-27

### Added

- `gemkeeper setup --global` writes the config to the system-wide location used by the Homebrew service (`/opt/homebrew/etc/gemkeeper.yml` on Apple Silicon, `/usr/local/etc/gemkeeper.yml` on Intel, `~/.config/gemkeeper/config.yml` as a fallback) rather than the current project directory.
  Data paths (`repos_path`, `gems_path`) are written as absolute paths under the corresponding `var` directory so the daemon finds them regardless of working directory.
  Use this flag when running gemkeeper as a shared `brew services` daemon instead of a per-project process.
- `--global` and `--config` are mutually exclusive; passing both exits with an error.

## [0.2.1] - 2026-05-19

### Fixed

- RuboCop offenses in sync command and executable (numeric predicate style, `delete_prefix`, parentheses, cyclomatic complexity).

## [0.2.0] - 2026-05-19

### Fixed

- `version: latest` now caches by the resolved gemspec version rather than the string "latest" — re-running `sync` is a no-op if the tip hasn't changed.
- Explicit versions accept both `v`-prefixed (`v1.2.3`) and bare semver (`1.2.3`) tag formats; the cache key is normalized to bare semver in both cases.
- `gemkeeper --help` and `gemkeeper server --help` now exit 0.
- Port validation raises a clear error at config load time rather than failing mid-command.
- Running the `gemkeeper` executable directly (without `bundle exec`) no longer raises a load error.

### Changed

- Sync output uses ANSI colors (TTY only) to distinguish progress steps, skips, and failures.
- `sync` prints a summary line on completion: `Sync complete: 2 synced, 1 skipped (3 total)`.
- Version reading for `version: latest` follows `require_relative` in the gemspec and falls back to globbing `lib/**/version.rb`, covering the common pattern where the version lives in a separate constant file.

## [0.1.0] - 2026-01-29

- Initial release

[Unreleased]: https://github.com/danhorst/gemkeeper/compare/v0.7.2...HEAD
[0.7.2]: https://github.com/danhorst/gemkeeper/compare/0.7.1...0.7.2
[0.7.1]: https://github.com/danhorst/gemkeeper/compare/0.7.0...0.7.1
[0.7.0]: https://github.com/danhorst/gemkeeper/compare/0.6.7...0.7.0
[0.6.7]: https://github.com/danhorst/gemkeeper/compare/0.6.6...0.6.7
[0.6.6]: https://github.com/danhorst/gemkeeper/compare/0.6.5...0.6.6
[0.6.5]: https://github.com/danhorst/gemkeeper/compare/0.6.4...0.6.5
[0.6.4]: https://github.com/danhorst/gemkeeper/compare/0.6.3...0.6.4
[0.6.3]: https://github.com/danhorst/gemkeeper/compare/0.6.2...0.6.3
[0.6.2]: https://github.com/danhorst/gemkeeper/compare/0.6.1...0.6.2
[0.6.1]: https://github.com/danhorst/gemkeeper/compare/0.6.0...0.6.1
[0.6.0]: https://github.com/danhorst/gemkeeper/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/danhorst/gemkeeper/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/danhorst/gemkeeper/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/danhorst/gemkeeper/compare/0.2.1...0.3.0
[0.2.1]: https://github.com/danhorst/gemkeeper/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/danhorst/gemkeeper/compare/0.1.0...0.2.0
