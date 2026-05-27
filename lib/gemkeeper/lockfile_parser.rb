# frozen_string_literal: true

module Gemkeeper
  # Locates the nearest Gemfile.lock by walking up; callers don't need to know the search algorithm.
  class LockfileParser
    LOCKFILE_NAME = "Gemfile.lock"

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

    def initialize(lockfile_path)
      @lockfile_path = lockfile_path
    end

    def gem_versions
      content = File.read(@lockfile_path)
      extract_gem_section(content)
    end

    private

    def extract_gem_section(content)
      versions = {}
      in_gem_specs = false

      content.each_line do |line|
        stripped = line.strip
        if stripped == "GEM"
          in_gem_specs = true
          next
        end

        # A new top-level section (no leading spaces) ends the GEM block
        in_gem_specs = false if in_gem_specs && line =~ /\A[A-Z]/ && stripped != "GEM"

        next unless in_gem_specs

        # Spec lines look like: "    gem_name (version)" — exactly 4 spaces, no deeper indent
        versions[Regexp.last_match(1)] = Regexp.last_match(2) if line.chomp =~ /\A    ([a-zA-Z0-9_-]+) \(([^)]+)\)\z/
      end

      versions
    end
  end
end
