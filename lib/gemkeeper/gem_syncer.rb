# frozen_string_literal: true

require "rubygems/package"

module Gemkeeper
  # Syncs a single gem: checks the server, reuses a built artifact, or builds
  # from source, then uploads. Repo acquisition is delegated to RepoFetcher.
  class GemSyncer
    def initialize(config, uploader, manifest:)
      @config   = config
      @uploader = uploader
      @fetcher  = RepoFetcher.new(manifest, config.repos_path)
    end

    def sync(gem_def)
      gem_def.latest? ? sync_latest(gem_def) : sync_pinned(gem_def)
    end

    private

    # Pinned / from_lockfile: version is known without the repo, so check the
    # server first, then reuse a local artifact, and only build as a last resort.
    def sync_pinned(gem_def)
      name    = gem_def.name
      version = resolve_version(gem_def)
      return skip(name, version) if @uploader.serves?(name, version)

      artifact = File.join(@config.gems_path, "#{name}-#{version}.gem")
      return reupload(artifact, name, version) if reusable_artifact?(artifact, name, version)

      build_and_upload(gem_def, version)
    end

    # latest: the version is only known after checkout, so the repo is always
    # fetched; the server check then decides whether the resolved version uploads.
    def sync_latest(gem_def)
      repo, local_path = @fetcher.fetch(gem_def)
      version = repo.current_version or
        raise BuildError, "Could not read version from gemspec for #{gem_def.name}"
      return skip(gem_def.name, version) if @uploader.serves?(gem_def.name, version)

      build_gem(local_path)
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

    def build_and_upload(gem_def, version)
      repo, local_path = @fetcher.fetch(gem_def)
      Output.step("Checking out #{version}...")
      repo.checkout_version(version)
      build_gem(local_path)
    end

    def build_gem(local_path)
      Output.step("Building gem...")
      gem_path = GemBuilder.new(local_path, @config.gems_path).build
      upload(gem_path)
      :synced
    end

    # Reuse a previously built artifact only if its embedded spec matches the
    # requested gem — never upload the wrong file because a name collided.
    def reusable_artifact?(path, name, version)
      return false unless File.exist?(path)

      spec = Gem::Package.new(path).spec
      spec.name == name && spec.version.to_s == version
    rescue StandardError
      false
    end

    def reupload(path, name, version)
      Output.step("Uploading cached #{name} @ #{version} (no rebuild)...")
      upload(path)
      :synced
    end

    def upload(path)
      result = @uploader.upload(path)
      Output.step(result[:message])
      Output.success("  Done!")
    end

    def skip(name, version)
      Output.skip("Skipping #{name} @ #{version} (already on server)")
      :skipped
    end
  end
end
