# frozen_string_literal: true

require "set"
require "timeout"
require "yaml"

module Gemkeeper
  # Validates a manifest file structurally and, optionally, by probing git remotes.
  class ManifestValidator
    VALID_GIT_URL = %r{\A(git@|https?://|ssh://)}
    VALID_HTTP_URL = %r{\Ahttps?://}
    RESOLVE_TIMEOUT = 5

    def initialize(path)
      @path = path
    end

    def validate(resolve: false, output: $stdout)
      errors = static_errors
      return errors if errors.any?

      errors + (resolve ? resolve_errors(output) : [])
    end

    private

    def static_errors
      return ["File not found: #{@path}"] unless File.exist?(@path)

      data = load_yaml
      return [data] if data.is_a?(String)

      structure_errors(data) + entry_errors(data)
    end

    def load_yaml
      @data = YAML.safe_load_file(@path, permitted_classes: [], symbolize_names: false) || {}
    rescue Psych::SyntaxError => e
      "Invalid YAML: #{e.message}"
    end

    def structure_errors(data)
      errors = []
      source_url = data["source_url"].to_s
      errors << "source_url is not a valid HTTP(S) URL" if data.key?("source_url") && !source_url.match?(VALID_HTTP_URL)
      errors << "gems must be a list" if data.key?("gems") && !data["gems"].is_a?(Array)
      errors
    end

    def entry_errors(data)
      return [] unless data["gems"].is_a?(Array)

      seen = Set.new
      data["gems"].each_with_index.flat_map { |entry, i| single_entry_errors(entry, i, seen) }
    end

    def single_entry_errors(entry, index, seen)
      name = entry["name"].to_s.strip
      repo = entry["repo"].to_s.strip
      label = name.empty? ? "gems[#{index}]" : "gems[#{index}] (#{name})"

      field_errors(label, name, repo) + duplicate_errors(label, name, seen)
    end

    def field_errors(label, name, repo)
      errors = []
      errors << "#{label}: missing name" if name.empty?
      errors << "#{label}: missing repo" if repo.empty?
      errors << "#{label}: repo does not look like a git URL" if !repo.empty? && !repo.match?(VALID_GIT_URL)
      errors
    end

    def duplicate_errors(label, name, seen)
      return [] if name.empty?

      if seen.include?(name)
        ["#{label}: duplicate name"]
      else
        seen << name
        []
      end
    end

    def resolve_errors(output)
      (@data["gems"] || []).flat_map { |entry| probe_repo(entry["name"], entry["repo"], output) }
    end

    def probe_repo(name, repo, output)
      reachable = Timeout.timeout(RESOLVE_TIMEOUT) do
        system("git", "ls-remote", repo, "--quiet", out: File::NULL, err: File::NULL)
      end
      output.puts "  #{name}: #{reachable ? "reachable" : "FAILED"}"
      reachable ? [] : ["#{name} (#{repo}): unreachable"]
    rescue Timeout::Error
      output.puts "  #{name}: timed out"
      ["#{name} (#{repo}): timed out after #{RESOLVE_TIMEOUT}s"]
    end
  end
end
