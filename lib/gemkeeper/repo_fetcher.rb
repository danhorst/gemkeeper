# frozen_string_literal: true

module Gemkeeper
  # Resolves a gem's source repo URL (manifest lookup, with an optional
  # gemkeeper.yml override) and clones or pulls it, mapping git authentication
  # failures to actionable guidance.
  class RepoFetcher
    AUTH_ERROR_PATTERNS = [
      /authentication failed/i,
      /could not read from remote repository/i,
      /permission denied \(publickey\)/i,
      /repository not found/i,
      /fatal: credential/i
    ].freeze

    def initialize(manifest, repos_path)
      @manifest   = manifest
      @repos_path = repos_path
    end

    # Resolves the repo URL, clones/pulls it, and returns [GitRepository, local_path].
    def fetch(gem_def)
      local_path = File.join(@repos_path, gem_def.name)
      [clone_or_pull(resolve(gem_def), local_path), local_path]
    end

    # Explicit repo: in gemkeeper.yml wins, but warns on divergence from the
    # manifest. Otherwise the repo is resolved from the manifest by gem name.
    def resolve(gem_def)
      name = gem_def.name
      override = gem_def.repo
      manifest_repo = @manifest.repo_for(name)
      return manifest_repo || missing_repo!(name) unless override

      warn_if_divergent(name, override, manifest_repo)
      override
    end

    private

    def missing_repo!(name)
      path = @manifest.path
      unless File.exist?(path)
        raise InvalidConfigError,
              "No manifest found at #{path} — run 'gemkeeper manifest generate' to create one"
      end

      raise InvalidConfigError,
            "No repo configured for #{name.inspect} — add it to the manifest with 'gemkeeper manifest generate'"
    end

    def warn_if_divergent(name, override, manifest_repo)
      return unless manifest_repo && manifest_repo != override

      warn "Warning: repo for #{name} in gemkeeper.yml (#{override}) " \
           "differs from manifest (#{manifest_repo}) — using gemkeeper.yml"
    end

    def clone_or_pull(repo_url, local_path)
      repo = GitRepository.new(repo_url, local_path)
      Output.step("Fetching from #{repo_url}...")
      repo.clone_or_pull
      repo
    rescue GitError => git_error
      raise auth_error?(git_error) ? auth_failure_error(repo_url, git_error) : git_error
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
