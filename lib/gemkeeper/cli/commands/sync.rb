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
          counts, failures = run_sync(gems_to_sync, config, uploader)
          report_results(counts, failures, gems_to_sync.size)
        end

        private

        def select_gems(config, gem_name)
          all_gems = config.gems
          if all_gems.empty?
            warn "No gems configured. Add gems to your gemkeeper.yml file."
            exit 1
          end

          gems = gem_name ? all_gems.select { |gem| gem.name == gem_name } : all_gems

          if gems.empty?
            warn "No matching gem found: #{gem_name}"
            exit 1
          end

          gems
        end

        def run_sync(gems_to_sync, config, uploader)
          counts = { synced: 0, skipped: 0 }
          failures = []
          gems_to_sync.each do |gem_def|
            result = sync_gem(gem_def, config, uploader)
            counts[result] += 1
          rescue Error => error
            failures << { name: gem_def.name, message: error.message }
          end
          [counts, failures]
        end

        def report_results(counts, failures, total)
          parts = []
          parts << Output.colorize("#{counts[:synced]} synced", :green) if counts[:synced].positive?
          parts << Output.colorize("#{counts[:skipped]} skipped", :yellow) if counts[:skipped].positive?
          parts << Output.colorize("#{failures.size} failed", :red) if failures.any?
          puts "\nSync complete: #{parts.join(", ")} (#{total} total)"

          return if failures.empty?

          warn "\nSync completed with #{failures.size} failure(s):"
          failures.each { |f| warn "  #{f[:name]}: #{f[:message]}" }
          exit 1
        end

        def sync_gem(gem_def, config, uploader)
          name = gem_def.name
          repo_url = gem_def.repo
          gems_path = config.gems_path
          version = resolve_version(gem_def)

          return :skipped if !gem_def.latest? && cached?(name, version, gems_path)

          puts "Syncing #{name} @ #{version}..."

          local_path = File.join(config.repos_path, name)
          repo = GitRepository.new(repo_url, local_path)

          Output.step("Fetching from #{repo_url}...")
          fetch_repo(repo, repo_url)

          checkout_gem_version(repo, version)

          if gem_def.latest?
            version = repo.current_version or
              raise BuildError, "Could not read version from gemspec in #{repo_url}"
            return :skipped if cached?(name, version, gems_path)
          end

          Output.step("Building gem...")
          gem_path = GemBuilder.new(local_path, config.gems_path).build

          Output.step("Uploading to Geminabox...")
          result = uploader.upload(gem_path)
          Output.step(result[:message])
          Output.success("  Done!")
          :synced
        end

        def resolve_version(gem_def)
          return gem_def.version unless gem_def.from_lockfile?

          name = gem_def.name
          lockfile_path = LockfileParser.find
          unless lockfile_path
            raise GitError,
                  "version: from_lockfile for #{name} — no Gemfile.lock found in " \
                  "#{Dir.pwd} or any parent directory"
          end

          versions = LockfileParser.parse(lockfile_path)
          version = versions[name]
          raise GitError, "#{name} not found in #{lockfile_path}" unless version

          version
        end

        def cached?(name, version, gems_path)
          bare_version = version.delete_prefix("v")
          gem_file = File.join(gems_path, "gems", "#{name}-#{bare_version}.gem")
          if File.exist?(gem_file)
            Output.skip("Skipping #{name} @ #{bare_version} (already cached)")
            true
          else
            false
          end
        end

        def fetch_repo(repo, repo_url)
          repo.clone_or_pull
        rescue GitError => git_error
          raise auth_error?(git_error) ? auth_failure_error(repo_url, git_error) : git_error
        end

        def checkout_gem_version(repo, version)
          Output.step("Checking out #{version}...")
          repo.checkout_version(version)
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
