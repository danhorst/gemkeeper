# frozen_string_literal: true

require "yaml"

module Gemkeeper
  # Isolates merge/build logic from CLI commands so setup-adjacent features share a single path.
  class ConfigGenerator
    def initialize(manifest:, lockfile_versions:)
      @manifest = manifest
      @lockfile_versions = lockfile_versions
    end

    def build(output_path, force:, global_output_path: nil)
      existing = force ? {} : (load_existing(output_path) || {})
      matched = matched_gems

      existing.empty? ? build_fresh(matched, global_output_path:) : merge(existing, matched)
    end

    private

    def matched_gems
      matched = @manifest.gems.filter_map do |gem_entry|
        name = gem_entry[:name]
        { name: } if @lockfile_versions.key?(name)
      end
      warn_unmatched
      matched
    end

    def warn_unmatched
      @lockfile_versions.each_key do |gem_name|
        next if @manifest.find_by_name(gem_name)

        prefix = gem_name.split("-").first
        next unless @manifest.gem_names.any? { |n| n.split("-").first == prefix }

        warn "Warning: #{gem_name} matches an internal name pattern but is not in the manifest — skipping"
      end
    end

    def load_existing(path)
      return nil unless File.exist?(path)

      YAML.safe_load_file(path, permitted_classes: [], symbolize_names: false) || {}
    end

    def build_fresh(matched, global_output_path: nil)
      repos_path, gems_path = data_paths_for(global_output_path)
      gem_entries = matched.map { |g| { "name" => g[:name], "version" => "from_lockfile" } }
      { "port" => Configuration::DEFAULT_PORT, "repos_path" => repos_path,
        "gems_path" => gems_path, "gems" => gem_entries }
    end

    def data_paths_for(global_output_path)
      return ["./cache/repos", "./cache/gems"] unless global_output_path

      data_dir = Configuration.global_data_dir(global_output_path)
      [File.join(data_dir, "repos"), File.join(data_dir, "gems")]
    end

    def merge(existing, matched)
      existing_gems = existing["gems"] || []
      new_by_name = matched.to_h do |g|
        [g[:name], { "name" => g[:name], "version" => "from_lockfile" }]
      end

      updated = existing_gems.map do |entry|
        name = canonical_name(entry)
        if (new_entry = new_by_name.delete(name))
          entry.except("version", "repo", "name").merge(new_entry)
        else
          entry
        end
      end

      updated += new_by_name.values
      existing.merge("gems" => updated)
    end

    def canonical_name(entry)
      return entry["name"] if entry["name"]

      repo = entry["repo"].to_s
      manifest_entry = @manifest.gems.find { |g| g[:repo] == repo }
      manifest_entry&.fetch(:name) || File.basename(repo, ".git").sub(/^ruby-/, "")
    end
  end
end
