# Gemkeeper

An opinionated wrapper around [Gem in a Box](https://github.com/geminabox/geminabox) for managing private gem dependencies in offline development environments.

## Installation

### Via RubyGems

```bash
gem install gemkeeper
```

### Via Homebrew (macOS)

```bash
brew tap danhorst/gemkeeper
brew install gemkeeper
```

## Quick Start

1. Create a configuration file at `~/.config/gemkeeper/config.yml`:

```yaml
port: 9292
gems:
  - repo: git@github.com:company/internal-gem.git
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
  - repo: git@github.com:company/gem-one.git
    version: latest    # Use the latest commit on main/master

  - repo: git@github.com:company/gem-two.git
    version: v1.2.3    # Use a specific tag

  - repo: git@github.com:company/ruby-gem-three.git
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

If installed via Homebrew:

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

1. **Clone/Pull**: Gemkeeper clones (or pulls) gem repositories to a local cache
2. **Build**: Builds `.gem` files from the source at the specified version/tag
3. **Upload**: Uploads built gems to a local Geminabox server
4. **Proxy**: Geminabox proxies public gems from RubyGems.org, so you only need one gem source

This allows offline Rails development with private gems when disconnected from VPN.

## Development

```bash
bundle install
bundle exec rake test    # Run tests
bundle exec rubocop      # Run linter
```

## License

MIT License. See [LICENSE.txt](LICENSE.txt).
