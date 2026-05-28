# frozen_string_literal: true

require "yaml"
require "fileutils"

module Gemkeeper
  # Decouples manifest format from sync/setup commands that need the eligible gem list.
  class ManifestReader
    DEFAULT_PATH = File.expand_path("~/.config/gemkeeper/manifest.yml")

    attr_reader :gems, :source_url

    def self.load(path = DEFAULT_PATH)
      new(path)
    end

    def initialize(path)
      @path = path
      @gems = []
      @source_url = nil
      parse_manifest if File.exist?(@path)
    end

    def clear!
      @gems = []
      @source_url = nil
      self
    end

    def gem_names
      @gems.map { |gem_entry| gem_entry[:name] }
    end

    def find_by_name(name)
      @gems.find { |gem_entry| gem_entry[:name] == name }
    end

    def repo_for(name)
      find_by_name(name)&.fetch(:repo)
    end

    # Adds a name→repo mapping. Idempotent for identical entries.
    # Raises ManifestConflictError if the name exists with a different repo.
    def add_mapping(name:, repo:)
      existing = find_by_name(name)
      if existing
        raise ManifestConflictError, conflict_message(name, existing[:repo], repo) if existing[:repo] != repo
      else
        @gems << { name:, repo: }
      end
      self
    end

    def save(path = @path)
      FileUtils.mkdir_p(File.dirname(path))
      data = {}
      data["source_url"] = @source_url if @source_url
      data["gems"] = @gems.map { |g| { "name" => g[:name], "repo" => g[:repo] } }
      File.write(path, data.to_yaml)
    end

    private

    def parse_manifest
      data = YAML.safe_load_file(@path, permitted_classes: [], symbolize_names: true) || {}
      @source_url = data[:source_url]&.to_s
      @gems = (data[:gems] || []).map do |entry|
        { name: entry[:name].to_s, repo: entry[:repo].to_s }
      end
    end

    def conflict_message(name, existing_repo, new_repo)
      "Manifest conflict for #{name.inspect}: " \
        "existing repo #{existing_repo.inspect} differs from #{new_repo.inspect}"
    end
  end
end
