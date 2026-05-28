# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      class Setup < Dry::CLI::Command
        include CLI::LockfileResolution

        desc "Generate gemkeeper.yml from a Gemfile.lock"

        argument :source_path, type: :string, required: false,
                               desc: "Gemfile.lock, Gemfile, or directory (default: nearest Gemfile.lock)"
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
          not_a_lockfile!(resolved) unless lockfile?(resolved)

          setup_from_lockfile(resolved, output_path, options)
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

        def not_a_lockfile!(path)
          warn "Error: setup builds from a Gemfile.lock, Gemfile, or directory — got #{path}. " \
               "To populate the manifest, run 'gemkeeper manifest generate'."
          exit 1
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
