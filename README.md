![Gemkeeper](./img/gemkeeper.jpeg)

This project is an opinionated wrapper around [Gem in a Box][1] for managing private gem dependencies in an offline development environment.

## Installation

### Via RubyGems

```bash
gem install gemkeeper
```

### Via Homebrew (MacOS)

```bash
brew tap danhorst/tap
brew install danhorst/tap/gemkeeper
```

Forumla: [`danhorst/homebrew-tap`][2]

## Workstation Setup

If you cannot reach your organization's private gem server, follow these steps to use gemkeeper as a local proxy.

**Prerequisites:** You must have HTTPS access to the internal gem repositories on GitHub.
Configure GitHub credentials before step 4 — see [GitHub authentication docs][3].

1. Install gemkeeper:

```bash
gem install gemkeeper
```

2. Install your org's gem manifest:

Your organization should provide a command or file that writes `~/.config/gemkeeper/manifest.yml`.
This manifest lists the internal gems and their GitHub URLs, and may include the private gem source URL used in step 6.

3. Generate a `gemkeeper.yml` for your project:

```bash
gemkeeper setup path/to/Gemfile.lock
```

This reads the lockfile, cross-references the manifest, and writes a `gemkeeper.yml` in the current directory.
It also prints the `bundle config` command you will need in step 6.

4. Build and cache the internal gems:

```bash
gemkeeper sync
```

5. Start the local gem server:

```bash
gemkeeper server start
```

6. Point Bundler at the local server using the command printed by step 3:

```bash
bundle config set --local mirror.<your-private-gem-source-url> http://localhost:9292
```

Replace `<your-private-gem-source-url>` with the gem source URL declared in your `Gemfile` (the one that requires VPN or private credentials).
The mirror approach redirects gem resolution to your local Geminabox without modifying the committed `Gemfile` or `Gemfile.lock`.
Public gems are proxied from RubyGems.org automatically.

## Quick Start

1. Create a configuration file at `~/.config/gemkeeper/config.yml`:

```yaml
port: 9292
gems:
  - repo: https://github.com/company/internal-gem
    version: latest
```

2. Start the server:

```bash
gemkeeper server start
```

3. Configure your Rails app to use the local gem server:

```ruby
# Gemfile
source "http://localhost:9292" do
  gem "internal-gem"
end
```

4. Sync your gems:

```bash
gemkeeper sync
```

## Configuration

Gemkeeper looks for configuration files in these locations (in order):

1. `./gemkeeper.yml` (current directory)
2. `~/.config/gemkeeper/config.yml`
3. `~/.gemkeeper.yml`
4. `/usr/local/etc/gemkeeper.yml` (Homebrew on Intel)
5. `/opt/homebrew/etc/gemkeeper.yml` (Homebrew on Apple Silicon)

### Configuration Options

```yaml
# Port for the Geminabox server (default: 9292)
port: 9292

# Where to clone gem repositories (default: ./cache/repos)
repos_path: ./cache/repos

# Where to store built gems (default: ./cache/gems)
gems_path: ./cache/gems

# PID file location (default: ./cache/gemkeeper.pid)
pid_file: ./cache/gemkeeper.pid

# List of gems to manage
gems:
  # HTTPS is recommended — works without SSH key setup (alternative: git@github.com:company/gem-one.git)
  - repo: https://github.com/company/gem-one
    version: latest    # Use the latest commit on main/master; cached by resolved gemspec version

  - repo: https://github.com/company/gem-two
    version: v1.2.3    # Use a specific tag; both v-prefixed and bare semver accepted

  - repo: https://github.com/company/gem-two
    version: from_lockfile    # Read version from the nearest Gemfile.lock

  - repo: https://github.com/company/ruby-gem-three
    name: gem-three    # Override the gem name (strips "ruby-" prefix by default)
```

## CLI Commands

### Server Management

```bash
# Start the server (daemonized)
gemkeeper server start

# Start in foreground (for services/debugging)
gemkeeper server start --foreground
gemkeeper server start -f

# Start on a specific port
gemkeeper server start --port 8080

# Stop the server
gemkeeper server stop

# Check server status
gemkeeper server status
```

### Project Setup

```bash
# Generate gemkeeper.yml from a Gemfile.lock and org manifest
gemkeeper setup path/to/Gemfile.lock

# Use an existing gemkeeper.yml as input (updates manifest, optionally installs as global config)
gemkeeper setup path/to/gemkeeper.yml

# Use a custom manifest path
gemkeeper setup path/to/Gemfile.lock --manifest ~/.config/myorg/manifest.yml

# Write gemkeeper.yml to a specific path
gemkeeper setup path/to/Gemfile.lock --config path/to/output.yml

# Overwrite existing gemkeeper.yml entirely
gemkeeper setup path/to/Gemfile.lock --force

# Skip auto-configuring Bundler mirrors
gemkeeper setup path/to/Gemfile.lock --skip-bundler-config

# Write to the global Homebrew service config instead of the current directory
gemkeeper setup path/to/Gemfile.lock --global
```

`--global` targets the system-wide config used by `brew services` — `/opt/homebrew/etc/gemkeeper.yml` on Apple Silicon or `/usr/local/etc/gemkeeper.yml` on Intel.
It sets `repos_path` and `gems_path` as absolute paths under the corresponding `var` directory so the daemon finds them regardless of which directory you run commands from.
`--global` and `--config` are mutually exclusive.

### Manifest Management

The manifest (`~/.config/gemkeeper/manifest.yml`) is the global name→repo lookup table shared across projects.
`manifest generate` builds or updates it; `setup` reads it.

```bash
# Build or update the manifest from a Gemfile.lock
gemkeeper manifest generate path/to/Gemfile.lock

# Use a custom manifest path
gemkeeper manifest generate path/to/Gemfile.lock --manifest ~/.config/myorg/manifest.yml

# Overwrite the manifest entirely (discard existing entries)
gemkeeper manifest generate path/to/Gemfile.lock --force

# Validate the default manifest
gemkeeper manifest validate

# Validate a specific manifest file
gemkeeper manifest validate path/to/manifest.yml

# Validate and probe each repo via git ls-remote
gemkeeper manifest validate --resolve
```

### Gem Synchronization

```bash
# Sync all configured gems
gemkeeper sync

# Sync a specific gem
gemkeeper sync internal-gem
```

### Other Commands

```bash
# List cached gems
gemkeeper list

# Show version
gemkeeper version
```

### Global Options

All commands support:

```bash
--config PATH    # Use a specific config file
```

## Running as a Service

### Homebrew Services (macOS)

If installed via Homebrew, gemkeeper can run as a shared system daemon — one server, all projects.

**Configure the service** from any project that has a `Gemfile.lock`:

```bash
gemkeeper setup path/to/Gemfile.lock --global
```

This writes `/opt/homebrew/etc/gemkeeper.yml` (Apple Silicon) or `/usr/local/etc/gemkeeper.yml` (Intel) with absolute data paths.
Run it again from any other project to merge its gems into the shared config.

**Manage the daemon:**

```bash
# Start and enable at login
brew services start gemkeeper

# Stop the service
brew services stop gemkeeper

# Check status
brew services info gemkeeper
```

### Manual Background Mode

```bash
# Start daemonized
gemkeeper server start

# Check if running
gemkeeper server status

# Stop
gemkeeper server stop
```

## How It Works

1. **Clone/Pull**: Gemkeeper clones (or pulls) gem repositories to a local cache.
2. **Build**: Builds `.gem` files from the source at the specified version/tag.
3. **Upload**: Uploads built gems to a local Geminabox server.
4. **Proxy**: Geminabox proxies public gems from RubyGems.org, so you only need one gem source.

This lets you use a combination of public and private gems from a single gem source.

## Development

```bash
bundle install
bundle exec rake test    # Run tests
bundle exec rubocop      # Run linter
```

[1]: https://github.com/geminabox/geminabox
[2]: https://github.com/danhorst/homebrew-tap
[3]: https://docs.github.com/en/authentication
