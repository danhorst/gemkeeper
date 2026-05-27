# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      class Setup < Dry::CLI::Command
        desc "Generate gemkeeper.yml from a Gemfile.lock and org manifest"

        argument :lockfile_path, type: :string, required: true,
                                 desc: "Path to the project's Gemfile.lock"
        option :manifest, type: :string,
                          desc: "Path to gem manifest (default: ~/.config/gemkeeper/manifest.yml)"
        option :config, type: :string, desc: "Path to write gemkeeper.yml (default: ./gemkeeper.yml)"
        option :global, type: :boolean, default: false,
                        desc: "Write to the global service config (for use with brew services)"
        option :force, type: :boolean, default: false,
                       desc: "Overwrite existing gemkeeper.yml entirely"

        def call(lockfile_path:, **options)
          validate_options!(options)

          output_path = resolve_output_path(options)
          manifest = ManifestReader.load(options[:manifest] || ManifestReader::DEFAULT_PATH)
          lockfile_versions = LockfileParser.parse(lockfile_path)
          global_output_path = options[:global] ? output_path : nil

          config = ConfigGenerator.new(manifest:, lockfile_versions:)
                                  .build(output_path, force: options[:force], global_output_path:)

          File.write(output_path, config.to_yaml)
          puts "Wrote #{output_path}"
          print_bundler_instructions(config, manifest)
        rescue ManifestNotFoundError => e
          warn "Error: #{e.message}"
          exit 1
        end

        private

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

        def print_bundler_instructions(config, manifest)
          port = config.fetch("port", Configuration::DEFAULT_PORT)
          local_url = "http://localhost:#{port}"
          source_url = manifest.source_url
          puts ""
          puts "To point Bundler at your local Geminabox, run:"
          if source_url
            puts "  bundle config set --local mirror.#{source_url} #{local_url}"
          else
            puts "  bundle config set --local mirror.<your-private-gem-source-url> #{local_url}"
            puts "  (Replace <your-private-gem-source-url> with the gem source URL from your Gemfile)"
          end
        end
      end
    end

    register "setup", Commands::Setup
  end
end
