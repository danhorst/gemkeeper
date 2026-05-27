# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      class Setup < Dry::CLI::Command
        desc "Generate gemkeeper.yml from a Gemfile.lock or existing gemkeeper.yml"

        argument :source_path, type: :string, required: true,
                               desc: "Path to a Gemfile.lock or gemkeeper.yml"
        option :manifest, type: :string,
                          desc: "Path to gem manifest (default: ~/.config/gemkeeper/manifest.yml)"
        option :config, type: :string, desc: "Path to write gemkeeper.yml (default: ./gemkeeper.yml)"
        option :global, type: :boolean, default: false,
                        desc: "Write to the global service config (for use with brew services)"
        option :force, type: :boolean, default: false,
                       desc: "Overwrite existing gemkeeper.yml entirely"
        option :skip_bundler_config, type: :boolean, default: false,
                                     desc: "Skip configuring Bundler mirrors for private gem sources"

        def call(source_path:, **options)
          validate_options!(options)
          output_path = resolve_output_path(options)

          if lockfile?(source_path)
            setup_from_lockfile(source_path, output_path, options)
          else
            setup_from_config(source_path, output_path, options)
          end
        rescue UnresolvableGemError, ManifestConflictError => error
          warn "Error: #{error.message}"
          exit 1
        end

        private

        def lockfile?(path)
          File.extname(path) == ".lock" || File.basename(path) == "Gemfile.lock"
        end

        def setup_from_lockfile(lockfile_path, output_path, options)
          manifest = load_manifest(options)
          candidates = LockfileParser.internal_sources(lockfile_path)

          unless candidates.empty?
            GemRepoResolver.new(candidates:, manifest:).resolve!
            manifest.save(manifest_path(options))
          end

          lockfile_versions = LockfileParser.parse(lockfile_path)
          global_output_path = options[:global] ? output_path : nil
          config = ConfigGenerator.new(manifest:, lockfile_versions:)
                                  .build(output_path, force: options[:force], global_output_path:)

          File.write(output_path, config.to_yaml)
          puts "Wrote #{output_path}"
          configure_bundler(candidates, config, options) unless options[:skip_bundler_config]
        end

        def configure_bundler(candidates, config, options)
          remotes = candidates.filter_map { |c| c[:remote] if c[:source_type] == :private_gem }.uniq
          return if remotes.empty?

          port = config.fetch("port", Configuration::DEFAULT_PORT)
          local_url = "http://localhost:#{port}"
          scope = options[:global] ? "--global" : "--local"

          puts ""
          remotes.each do |remote|
            if system("bundle", "config", "set", scope, "mirror.#{remote}", local_url, out: File::NULL)
              puts "Configured: bundle config set #{scope} mirror.#{remote} #{local_url}"
            else
              warn "Warning: failed to configure bundler mirror for #{remote}"
              warn "  Run manually: bundle config set #{scope} mirror.#{remote} #{local_url}"
            end
          end
        end

        def setup_from_config(source_path, output_path, options)
          source = YAML.safe_load_file(source_path, permitted_classes: [], symbolize_names: false) || {}
          manifest = load_manifest(options)
          update_manifest_from_config(source, manifest, options)
          install_global_config(source, output_path) if options[:global]
        end

        def update_manifest_from_config(source, manifest, options)
          (source["gems"] || []).each do |entry|
            repo = entry["repo"].to_s
            next if repo.empty?

            name = File.basename(repo, ".git").sub(/^ruby-/, "")
            manifest.add_mapping(name:, repo:)
          end
          manifest.save(manifest_path(options))
        end

        def install_global_config(source, output_path)
          existing = File.exist?(output_path) ? (YAML.safe_load_file(output_path) || {}) : {}
          merged = existing.merge(source.except("gems")).merge("gems" => merge_gem_lists(existing, source))
          File.write(output_path, merged.to_yaml)
          puts "Wrote #{output_path}"
        end

        def merge_gem_lists(existing, source)
          existing_gems = existing["gems"] || []
          source_gems = source["gems"] || []
          existing_repos = existing_gems.to_set { |g| g["repo"] }
          merged = existing_gems.dup
          source_gems.each { |g| merged << g unless existing_repos.include?(g["repo"]) }
          merged
        end

        def load_manifest(options)
          ManifestReader.load(manifest_path(options))
        end

        def manifest_path(options)
          options[:manifest] || ManifestReader::DEFAULT_PATH
        end

        def validate_options!(options)
          return unless options[:global] && options[:config]

          warn "Error: --global and --config are mutually exclusive"
          exit 1
        end

        def resolve_output_path(options)
          return options[:config] || File.join(Dir.pwd, Configuration::DEFAULT_CONFIG_FILENAME) unless options[:global]

          Configuration.resolve_global_path || no_global_path!
        end

        def no_global_path!
          warn "Error: no writable global config path found — install Homebrew or create ~/.config/gemkeeper/"
          exit 1
        end
      end
    end

    register "setup", Commands::Setup
  end
end
