# frozen_string_literal: true

require "open3"
require "fileutils"

module Gemkeeper
  class GitRepository
    attr_reader :repo_url, :local_path

    def initialize(repo_url, local_path)
      @repo_url = repo_url
      @local_path = local_path
    end

    def clone_or_pull
      if File.directory?(File.join(@local_path, ".git"))
        pull
      else
        clone
      end
    end

    SAFE_REF_PATTERN = /\A[a-zA-Z0-9._-]+\z/

    def checkout_version(version)
      if version == "latest"
        checkout_trunk
      else
        checkout_tag(version)
      end
    end

    def current_version
      gemspec_path = find_gemspec
      return nil unless gemspec_path

      content = File.read(gemspec_path)
      extract_version_from_content(content) ||
        version_from_requires(content, File.dirname(gemspec_path)) ||
        version_from_version_files
    end

    def find_gemspec
      Dir.glob(File.join(@local_path, "*.gemspec")).first
    end

    private

    def clone
      FileUtils.mkdir_p(File.dirname(@local_path))
      run_git("clone", @repo_url, @local_path)
    end

    def pull
      Dir.chdir(@local_path) do
        run_git("fetch", "--all", "--tags")
        trunk = detect_trunk_branch
        run_git("checkout", trunk)
        run_git("pull", "origin", trunk)
      end
    end

    def checkout_trunk
      Dir.chdir(@local_path) do
        trunk = detect_trunk_branch
        run_git("checkout", trunk)
        run_git("pull", "origin", trunk)
      end
    end

    def validate_ref!(ref)
      return if ref.match?(SAFE_REF_PATTERN)

      raise GitError, "Unsafe ref rejected: #{ref.inspect} — must match [a-zA-Z0-9._-]"
    end

    def extract_version_from_content(content)
      [
        /\.version\s*=\s*["']([^"']+)["']/,
        /\bVERSION\s*=\s*["']([^"']+)["']/
      ].each do |pattern|
        m = content.match(pattern)
        return m[1] if m
      end
      nil
    end

    def version_from_requires(content, base_dir)
      content.scan(/require_relative\s+["']([^"']+)["']/).each do |match|
        base = match[0].delete_suffix(".rb")
        path = File.expand_path("#{base}.rb", base_dir)
        next unless File.exist?(path)

        version = extract_version_from_content(File.read(path))
        return version if version
      end
      nil
    end

    def version_from_version_files
      Dir.glob(File.join(@local_path, "lib", "**", "version.rb")).each do |path|
        version = extract_version_from_content(File.read(path))
        return version if version
      end
      nil
    end

    def checkout_tag(version)
      bare = version.sub(/\Av/, "")
      validate_ref!(bare)
      Dir.chdir(@local_path) do
        run_git("fetch", "--all", "--tags")
        begin
          run_git("checkout", "v#{bare}")
        rescue GitError
          run_git("checkout", bare)
        end
      end
    rescue GitError
      raise GitError, "Could not find tag v#{bare} or #{bare} in #{@repo_url}"
    end

    def detect_trunk_branch
      Dir.chdir(@local_path) do
        stdout, = run_git("branch", "-r")
        remotes = stdout.lines.map(&:strip)

        %w[main master].each do |branch|
          return branch if remotes.any? { |remote| remote.end_with?("origin/#{branch}") }
        end

        raise GitError, "Cannot detect trunk branch (no main or master found)"
      end
    end

    def run_git(*args)
      cmd = ["git"] + args
      stdout, stderr, status = Open3.capture3(*cmd)

      raise GitError, "Git command failed: #{cmd.join(" ")}\n#{stderr}" unless status.success?

      [stdout, stderr]
    end
  end
end
