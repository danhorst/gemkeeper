# frozen_string_literal: true

require "open3"
require "fileutils"

module Gemkeeper
  class GemBuilder
    attr_reader :repo_path, :output_dir

    def initialize(repo_path, output_dir = nil)
      @repo_path = repo_path
      @output_dir = output_dir
    end

    def build
      gemspec_path = find_gemspec
      raise GemspecNotFoundError, "No gemspec found in #{@repo_path}" unless gemspec_path

      Dir.chdir(@repo_path) do
        gem_file = run_gem_build(gemspec_path)
        gem_path = File.join(@repo_path, gem_file)

        if @output_dir
          FileUtils.mkdir_p(@output_dir)
          dest_path = File.join(@output_dir, gem_file)
          FileUtils.mv(gem_path, dest_path)
          dest_path
        else
          gem_path
        end
      end
    end

    def gem_name
      gemspec_path = find_gemspec
      return nil unless gemspec_path

      File.basename(gemspec_path, ".gemspec")
    end

    private

    def find_gemspec
      Dir.glob(File.join(@repo_path, "*.gemspec")).first
    end

    def run_gem_build(gemspec_path)
      stdout, stderr, status = Open3.capture3("gem", "build", gemspec_path)

      raise BuildError, "Gem build failed:\n#{stderr}" unless status.success?

      # Parse the output to find the generated gem file
      unless stdout =~ /File:\s+(\S+\.gem)/
        raise BuildError, "Could not determine built gem file from output:\n#{stdout}"
      end

      Regexp.last_match(1)
    end
  end
end
