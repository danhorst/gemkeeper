# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      class Sync < Dry::CLI::Command
        desc "Sync gems from configured repositories"

        argument :gem_name, type: :string, required: false, desc: "Specific gem to sync"
        option :config, type: :string, desc: "Path to config file"

        def call(gem_name: nil, **options)
          config = Configuration.load(options[:config])
          gems_to_sync = select_gems(config, gem_name)
          uploader = GemUploader.new(config.geminabox_url)
          failures = run_sync(gems_to_sync, config, uploader)
          report_failures(failures)
        end

        private

        def select_gems(config, gem_name)
          if config.gems.empty?
            warn "No gems configured. Add gems to your gemkeeper.yml file."
            exit 1
          end

          gems = gem_name ? config.gems.select { |g| g.name == gem_name } : config.gems

          if gems.empty?
            warn "No matching gem found: #{gem_name}"
            exit 1
          end

          gems
        end

        def run_sync(gems_to_sync, config, uploader)
          failures = []
          gems_to_sync.each do |gem_def|
            sync_gem(gem_def, config, uploader)
          rescue Error => e
            failures << { name: gem_def.name, message: e.message }
          end
          failures
        end

        def report_failures(failures)
          return if failures.empty?

          warn "\nSync completed with #{failures.size} failure(s):"
          failures.each { |f| warn "  #{f[:name]}: #{f[:message]}" }
          exit 1
        end

        def sync_gem(gem_def, config, uploader)
          version = resolve_version(gem_def)
          return if cached?(gem_def.name, version, config.gems_path)

          puts "Syncing #{gem_def.name} @ #{version}..."

          local_path = File.join(config.repos_path, gem_def.name)
          repo = GitRepository.new(gem_def.repo, local_path)

          puts "  Fetching from #{gem_def.repo}..."
          begin
            repo.clone_or_pull
          rescue GitError => e
            raise auth_error?(e) ? auth_failure_error(gem_def.repo, e) : e
          end

          checkout_gem_version(repo, gem_def, version)

          puts "  Building gem..."
          gem_path = GemBuilder.new(local_path, config.gems_path).build

          puts "  Uploading to Geminabox..."
          result = uploader.upload(gem_path)
          puts "  #{result[:message]}"
          puts "  Done!"
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
          version = versions[gem_def.name]
          raise GitError, "#{gem_def.name} not found in #{lockfile_path}" unless version

          version
        end

        def cached?(name, version, gems_path)
          gem_file = File.join(gems_path, "gems", "#{name}-#{version}.gem")
          if File.exist?(gem_file)
            puts "Skipping #{name} @ #{version} (already cached)"
            true
          else
            false
          end
        end

        def checkout_gem_version(repo, gem_def, version)
          puts "  Checking out #{version}..."
          if gem_def.from_lockfile?
            repo.checkout_resolved_version(version)
          else
            repo.checkout_version(version)
          end
        end

        def auth_error?(error)
          auth_patterns = [
            /authentication failed/i,
            /could not read from remote repository/i,
            /permission denied \(publickey\)/i,
            /repository not found/i,
            /fatal: credential/i
          ]
          auth_patterns.any? { |pat| error.message.match?(pat) }
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

    register "sync", Commands::Sync
  end
end
