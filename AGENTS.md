# Gemkeeper

A Ruby CLI tool for managing offline development with private gem dependencies.

## Purpose

Automate building internal gems from source and caching them in a local Geminabox server for offline Rails development when disconnected from VPN.

## Architecture

- Ruby gem with CLI executable
- YAML config for gem repository definitions
- Git operations to clone/pull internal repos
- Build gems at specified versions/tags
- Upload to local Geminabox server
- Geminabox proxies public gems from RubyGems.org

## Config Example

```yaml
geminabox_url: http://localhost:9292

gems:
  - repo: git@github.com:company/internal-gem-1.git
    version: latest
  - repo: git@github.com:company/internal-gem-2.git
    version: v2.3.1
```

## CLI Commands (planned)

- `gemkeeper sync` - Build and upload all gems
- `gemkeeper sync <gem-name>` - Sync specific gem
- `gemkeeper list` - Show cached gems

## Current Status

Early development - scaffolding phase
