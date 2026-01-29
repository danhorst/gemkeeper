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
