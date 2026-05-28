# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      class Setup < Dry::CLI::Command
        desc "Generate gemkeeper.yml from a Gemfile.lock or existing gemkeeper.yml"

        argument :source_path, type: :string, required: false,
                               desc: "Gemfile.lock, Gemfile, directory, or gemkeeper.yml " \
                                     "(default: nearest Gemfile.lock)"
        option :manifest, type: :string,
                          desc: "Path to gem manifest (default: ~/.config/gemkeeper/manifest.yml)"
        option :config, type: :string, desc: "Path to write gemkeeper.yml (default: ./gemkeeper.yml)"
        option :global, type: :boolean, default: false,
                        desc: "Write to the global service config (for use with brew services)"
        option :force, type: :boolean, default: false,
                       desc: "Overwrite existing gemkeeper.yml entirely"
        option :skip_bundler_config, type: :boolean, default: false,
                                     desc: "Skip configuring Bundler mirrors for private gem sources"

        def call(source_path: nil, **options)
          validate_options!(options)
          output_path = resolve_output_path(options)
          resolved = resolve_source_path(source_path)

          if lockfile?(resolved)
            setup_from_lockfile(resolved, output_path, options)
          else
            setup_from_config(resolved, output_path, options)
          end
        rescue UnresolvableGemError, ManifestConflictError => error
          warn "Error: #{error.message}"
          exit 1
        end

        private

        def resolve_source_path(path)
          resolved = coerce_source_path(path)
          File.exist?(resolved) ? resolved : missing_source!(resolved)
        end

        def coerce_source_path(path)
          return (LockfileParser.find || no_lockfile!) if path.nil?
          return File.join(path, "Gemfile.lock") if File.directory?(path)
          return File.join(File.dirname(path), "Gemfile.lock") if File.basename(path) == "Gemfile"

          path
        end

        def lockfile?(path)
          File.extname(path) == ".lock" || File.basename(path) == "Gemfile.lock"
        end

        def setup_from_lockfile(lockfile_path, output_path, options)
          manifest = load_manifest(options)
          result = ManifestBuilder.build(lockfile_path:, manifest:)
          manifest.save(manifest_path(options)) if result.any_changes?

          lockfile_versions = LockfileParser.parse(lockfile_path)
          global_output_path = options[:global] ? output_path : nil
          config = ConfigGenerator.new(manifest:, lockfile_versions:)
                                  .build(output_path, force: options[:force], global_output_path:)

          File.write(output_path, config.to_yaml)
          puts "Wrote #{output_path}"
          return if options[:skip_bundler_config]

          port = config.fetch("port", Configuration::DEFAULT_PORT)
          resolved = result.candidates.select { |c| result.manifest.repo_for(c[:name]) }
          BundlerMirrorConfigurator.new(resolved, port:, global: options[:global]).configure
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
          existing_gems + source_gems.reject { |g| existing_repos.include?(g["repo"]) }
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

        def no_lockfile!
          warn "Error: no Gemfile.lock found in #{Dir.pwd} or any parent directory"
          exit 1
        end

        def missing_source!(path)
          warn "Error: file not found — #{path}"
          exit 1
        end
      end
    end

    register "setup", Commands::Setup
  end
end
