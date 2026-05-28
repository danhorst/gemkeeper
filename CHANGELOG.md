## [Unreleased]

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

[Unreleased]: https://github.com/danhorst/gemkeeper/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/danhorst/gemkeeper/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/danhorst/gemkeeper/compare/0.2.1...0.3.0
[0.2.1]: https://github.com/danhorst/gemkeeper/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/danhorst/gemkeeper/compare/0.1.0...0.2.0
