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
        validate_ref!(version)
        checkout_ref(version)
      end
    end

    def checkout_resolved_version(version)
      validate_ref!(version)
      Dir.chdir(@local_path) do
        run_git("fetch", "--all", "--tags")
        begin
          run_git("checkout", "v#{version}")
        rescue GitError
          run_git("checkout", version)
        end
      end
    rescue GitError
      raise GitError, "Could not find tag v#{version} or #{version} in #{@repo_url}"
    end

    def current_version
      gemspec_path = find_gemspec
      return nil unless gemspec_path

      content = File.read(gemspec_path)
      version_patterns = [
        /\.version\s*=\s*["']([^"']+)["']/,
        /VERSION\s*=\s*["']([^"']+)["']/
      ]

      version_patterns.each do |pattern|
        return Regexp.last_match(1) if content =~ pattern
      end
      nil
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

    def checkout_ref(ref)
      Dir.chdir(@local_path) do
        run_git("fetch", "--all", "--tags")
        run_git("checkout", ref)
      end
    end

    def detect_trunk_branch
      Dir.chdir(@local_path) do
        stdout, = run_git("branch", "-r")
        remotes = stdout.lines.map(&:strip)

        if remotes.any? { |r| r =~ %r{origin/main$} }
          "main"
        elsif remotes.any? { |r| r =~ %r{origin/master$} }
          "master"
        else
          raise GitError, "Cannot detect trunk branch (no main or master found)"
        end
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
