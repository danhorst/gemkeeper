# Gemkeeper

A Ruby CLI tool for managing offline development with private gem dependencies.

## Purpose

Automate building internal gems from source and caching them in a local Geminabox server for offline Rails development when disconnected from VPN.

## Architecture

- Ruby gem with CLI executable (`exe/gemkeeper`)
- YAML config for gem repository definitions
- Git operations to clone/pull internal repos
- Build gems at specified versions/tags
- Upload to local Geminabox server
- Geminabox proxies public gems from RubyGems.org

### Version resolution

`version: latest` — checkout trunk, then read actual gemspec version post-checkout for the cache key.
`version: v1.2.3` or `version: 1.2.3` — both accepted; `checkout_tag` normalizes by stripping the `v` prefix, then tries `v{bare}` first and falls back to `{bare}`.
`version: from_lockfile` — reads bare semver from nearest `Gemfile.lock`, then follows the same `checkout_tag` path.
Cache keys always use bare semver (no `v` prefix) so they match the filename `gem build` produces.

### Version reading (`current_version`)

Three-tier lookup: inline string in gemspec → follow `require_relative` lines to required files → glob `lib/**/version.rb`.
Returns `nil` if no version is found; `sync` raises `BuildError` in that case for `version: latest`.

### Output

`Gemkeeper::Output` (module functions) — `step`, `success`, `skip`, `failure`.
All color output is ANSI-gated on `$stdout.tty?`, so tests and pipes see plain text.

### dry-cli notes

Namespace-level help (`gemkeeper --help`, `gemkeeper server --help`) writes to stderr, not stdout, and exits 1 by default.
The exe rescues `SystemExit` and normalizes to 0 when `--help`/`-h` is in `ARGV`.

## Config Example

```yaml
port: 9292
repos_path: ./cache/repos
gems_path: ./cache/gems

gems:
  - repo: git@github.com:company/internal-gem-1.git
    version: latest
  - repo: git@github.com:company/internal-gem-2.git
    version: v2.3.1
```

## CLI Commands

- `gemkeeper version` - Print version
- `gemkeeper server start` - Start Geminabox server
- `gemkeeper server stop` - Stop Geminabox server
- `gemkeeper server status` - Check server status
- `gemkeeper sync` - Build and upload all configured gems
- `gemkeeper sync <gem-name>` - Sync specific gem
- `gemkeeper list` - Show locally uploaded gems

## Development

```bash
bundle install
bundle exec rake test    # Run tests
bundle exec rubocop      # Run linter
```

## Current Status

v1 complete - all core functionality implemented
