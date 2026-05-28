# frozen_string_literal: true

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
      load_from_disk if File.exist?(@path)
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
      ManifestSerializer.save(path, gems: @gems, source_url: @source_url)
    end

    private

    def load_from_disk
      data = ManifestSerializer.load(@path)
      @source_url = data[:source_url]&.to_s
      @gems = (data[:gems] || []).map { |entry| { name: entry[:name].to_s, repo: entry[:repo].to_s } }
    end

    def conflict_message(name, existing_repo, new_repo)
      "Manifest conflict for #{name.inspect}: " \
        "existing repo #{existing_repo.inspect} differs from #{new_repo.inspect}"
    end
  end
end
