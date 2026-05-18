# frozen_string_literal: true

require "yaml"

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
        option :force, type: :boolean, default: false,
                       desc: "Overwrite existing gemkeeper.yml entirely"

        def call(lockfile_path:, **options)
          manifest_path = options[:manifest] || ManifestReader::DEFAULT_PATH
          output_path = options[:config] || File.join(Dir.pwd, Configuration::DEFAULT_CONFIG_FILENAME)

          manifest = ManifestReader.load(manifest_path)
          lockfile_versions = LockfileParser.parse(lockfile_path)

          matched = match_gems(manifest, lockfile_versions)

          write_config(matched, output_path, force: options[:force])
          print_bundler_instructions(output_path, manifest)
        rescue ManifestNotFoundError => e
          warn "Error: #{e.message}"
          exit 1
        end

        private

        def match_gems(manifest, lockfile_versions)
          matched = manifest.gems.filter_map do |gem_entry|
            name = gem_entry[:name]
            { name: name, repo: gem_entry[:repo] } if lockfile_versions.key?(name)
          end

          warn_unmatched_internals(manifest, lockfile_versions)
          matched
        end

        def warn_unmatched_internals(manifest, lockfile_versions)
          lockfile_versions.each_key do |gem_name|
            next if manifest.find_by_name(gem_name)

            gem_prefix = gem_name.split("-").first
            next unless manifest.gem_names.any? { |manifest_name| manifest_name.split("-").first == gem_prefix }

            warn "Warning: #{gem_name} matches an internal name pattern but is not in the manifest — skipping"
          end
        end

        def write_config(matched_gems, output_path, force:)
          existing = load_existing_config(output_path) unless force
          existing ||= {}

          gem_entries = matched_gems.map do |gem_entry|
            { "repo" => gem_entry[:repo], "version" => "from_lockfile" }
          end

          config = if force || existing.empty?
                     build_fresh_config(gem_entries)
                   else
                     merge_config(existing, gem_entries, matched_gems)
                   end

          File.write(output_path, config.to_yaml)
          puts "Wrote #{output_path}"
        end

        def load_existing_config(path)
          return nil unless File.exist?(path)

          YAML.safe_load_file(path, permitted_classes: [], symbolize_names: false) || {}
        end

        def build_fresh_config(gem_entries)
          {
            "port" => Configuration::DEFAULT_PORT,
            "repos_path" => "./cache/repos",
            "gems_path" => "./cache/gems",
            "gems" => gem_entries
          }
        end

        def merge_config(existing, _new_gem_entries, matched_gems)
          existing_gems = existing["gems"] || []
          matched_names = matched_gems.map { |gem_entry| gem_entry[:name] }

          # Build a lookup for new entries by repo
          new_by_name = matched_gems.to_h do |gem_entry|
            [gem_entry[:name], { "repo" => gem_entry[:repo], "version" => "from_lockfile" }]
          end

          # Update existing entries for matched gems, keep others untouched
          updated = existing_gems.map do |entry|
            repo = entry["repo"].to_s
            name = File.basename(repo, ".git").sub(/^ruby-/, "")
            if matched_names.include?(name)
              new_by_name.delete(name).merge(entry.except("version")).merge("version" => "from_lockfile")
            else
              entry
            end
          end

          # Append any matched gems not already in the config
          updated += new_by_name.values

          existing.merge("gems" => updated)
        end

        def print_bundler_instructions(config_path, manifest)
          config = load_existing_config(config_path) || {}
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
