## [Unreleased]

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

[Unreleased]: https://github.com/danhorst/gemkeeper/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/danhorst/gemkeeper/compare/0.1.0...0.2.0
