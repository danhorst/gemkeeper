# frozen_string_literal: true

module Gemkeeper
  # Locates the nearest Gemfile.lock by walking up; callers don't need to know the search algorithm.
  class LockfileParser
    LOCKFILE_NAME = "Gemfile.lock"
    VERSION_SECTION_TYPES = %w[GEM GIT].freeze

    def self.find(start_dir = Dir.pwd)
      dir = File.expand_path(start_dir)
      loop do
        candidate = File.join(dir, LOCKFILE_NAME)
        return candidate if File.exist?(candidate)

        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end
      nil
    end

    def self.parse(lockfile_path)
      new(lockfile_path).gem_versions
    end

    def self.internal_sources(lockfile_path)
      new(lockfile_path).internal_sources
    end

    def initialize(lockfile_path)
      @lockfile_path = lockfile_path
    end

    # Returns name => version for all GEM and GIT section gems (excludes dependency lines).
    def gem_versions
      sections = parsed_sections
      sections.select { |s| VERSION_SECTION_TYPES.include?(s[:type]) }
              .each_with_object({}) { |section, versions| versions.merge!(versions_from_section(section)) }
    end

    # Returns an array of hashes describing gems from non-rubygems.org sources.
    # Each hash has :name, :source_type (:git or :private_gem), and either
    # :repo (for :git) or :remote (the private gem registry URL, for :private_gem).
    def internal_sources
      sections = parsed_sections
      extract_git_sources(sections) + extract_private_gem_sources(sections)
    end

    private

    def parsed_sections
      sections = []
      current = nil
      File.foreach(@lockfile_path) do |line|
        if line.match?(/\A[A-Z]/)
          sections << current if current
          current = { type: line.strip, lines: [] }
        elsif current
          current[:lines] << line
        end
      end
      sections << current if current
      sections
    end

    def versions_from_section(section)
      in_specs = false
      section[:lines].each_with_object({}) do |line, versions|
        if line.strip == "specs:"
          in_specs = true
        elsif in_specs && (match = line.chomp.match(/\A    ([a-zA-Z0-9_-]+) \(([^)]+)\)\z/))
          versions[match[1]] = match[2]
        end
      end
    end

    def extract_git_sources(sections)
      sections.select { |s| s[:type] == "GIT" }.flat_map do |section|
        remote = section_remote(section)
        specs_from_section(section).map { |name| { name:, repo: remote, source_type: :git } }
      end
    end

    def extract_private_gem_sources(sections)
      sections.select { |s| s[:type] == "GEM" }.flat_map do |section|
        remote = section_remote(section)
        next [] if rubygems_org?(remote)

        specs_from_section(section).map { |name| { name:, remote:, source_type: :private_gem } }
      end
    end

    def section_remote(section)
      section[:lines].each do |line|
        stripped = line.strip
        return stripped.delete_prefix("remote:").strip if stripped.start_with?("remote:")
      end
      nil
    end

    def specs_from_section(section)
      in_specs = false
      section[:lines].each_with_object([]) do |line, names|
        if line.strip == "specs:"
          in_specs = true
        elsif in_specs && (match = line.match(/\A    ([a-zA-Z0-9_-]+) \(/))
          names << match[1]
        end
      end
    end

    def rubygems_org?(remote)
      remote.to_s.include?("rubygems.org")
    end
  end
end
