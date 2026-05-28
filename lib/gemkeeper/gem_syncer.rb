# frozen_string_literal: true

module Gemkeeper
  # Syncs a single gem: resolves version, checks cache, clones/pulls, builds, uploads.
  class GemSyncer
    AUTH_ERROR_PATTERNS = [
      /authentication failed/i,
      /could not read from remote repository/i,
      /permission denied \(publickey\)/i,
      /repository not found/i,
      /fatal: credential/i
    ].freeze

    def initialize(config, uploader, manifest:)
      @config = config
      @uploader = uploader
      @manifest = manifest
    end

    def sync(gem_def)
      repo_url = resolve_repo(gem_def)
      version = resolve_version(gem_def)
      name = gem_def.name
      gems_path = @config.gems_path

      return :skipped if !gem_def.latest? && cached?(name, version, gems_path)

      puts "Syncing #{name} @ #{version}..."
      local_path = File.join(@config.repos_path, name)
      repo = fetch_repo(repo_url, local_path)

      Output.step("Checking out #{version}...")
      repo.checkout_version(version)

      if gem_def.latest?
        version = latest_version!(repo, name, gems_path, repo_url)
        return :skipped unless version
      end

      build_and_upload(local_path, gems_path)
      :synced
    end

    private

    # Explicit repo: in gemkeeper.yml wins, but warns on divergence from the manifest.
    # Otherwise the repo is resolved from the manifest by gem name.
    def resolve_repo(gem_def)
      manifest_repo = @manifest.repo_for(gem_def.name)
      return manifest_repo || missing_repo!(gem_def.name) unless gem_def.repo

      warn_if_divergent(gem_def.name, gem_def.repo, manifest_repo)
      gem_def.repo
    end

    def missing_repo!(name)
      unless File.exist?(@manifest.path)
        raise InvalidConfigError,
              "No manifest found at #{@manifest.path} — run 'gemkeeper manifest generate' to create one"
      end

      raise InvalidConfigError,
            "No repo configured for #{name.inspect} — add it to the manifest with 'gemkeeper manifest generate'"
    end

    def warn_if_divergent(name, config_repo, manifest_repo)
      return unless manifest_repo && manifest_repo != config_repo

      warn "Warning: repo for #{name} in gemkeeper.yml (#{config_repo}) " \
           "differs from manifest (#{manifest_repo}) — using gemkeeper.yml"
    end

    def resolve_version(gem_def)
      return gem_def.version unless gem_def.from_lockfile?

      lockfile_path = LockfileParser.find
      unless lockfile_path
        raise GitError,
              "version: from_lockfile for #{gem_def.name} — no Gemfile.lock found in " \
              "#{Dir.pwd} or any parent directory"
      end

      versions = LockfileParser.parse(lockfile_path)
      versions[gem_def.name] or raise GitError, "#{gem_def.name} not found in #{lockfile_path}"
    end

    def cached?(name, version, gems_path)
      bare = version.delete_prefix("v")
      gem_file = File.join(gems_path, "gems", "#{name}-#{bare}.gem")
      return false unless File.exist?(gem_file)

      Output.skip("Skipping #{name} @ #{bare} (already cached)")
      true
    end

    def fetch_repo(repo_url, local_path)
      repo = GitRepository.new(repo_url, local_path)
      Output.step("Fetching from #{repo_url}...")
      repo.clone_or_pull
      repo
    rescue GitError => git_error
      raise auth_error?(git_error) ? auth_failure_error(repo_url, git_error) : git_error
    end

    def latest_version!(repo, name, gems_path, repo_url)
      version = repo.current_version or
        raise BuildError, "Could not read version from gemspec in #{repo_url}"
      cached?(name, version, gems_path) ? nil : version
    end

    def build_and_upload(local_path, gems_path)
      Output.step("Building gem...")
      gem_path = GemBuilder.new(local_path, gems_path).build
      Output.step("Uploading to Geminabox...")
      result = @uploader.upload(gem_path)
      Output.step(result[:message])
      Output.success("  Done!")
    end

    def auth_error?(error)
      AUTH_ERROR_PATTERNS.any? { |pat| error.message.match?(pat) }
    end

    def auth_failure_error(repo_url, original_error)
      GitError.new(
        "Git authentication failed for #{repo_url}.\n" \
        "#{original_error.message}\n" \
        "Configure GitHub credentials: https://docs.github.com/en/authentication"
      )
    end
  end
end
