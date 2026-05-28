# frozen_string_literal: true

module Gemkeeper
  # Resolves gem candidates (from lockfile sources) to git repo URLs.
  # GIT-sourced gems are added automatically; private gem registry entries
  # are inferred where possible (GitHub Packages) or prompted interactively.
  class GemRepoResolver
    SKIP_INPUT = "skip"

    def initialize(candidates:, manifest:, input: $stdin, output: $stdout)
      @candidates = candidates
      @manifest = manifest
      @input = input
      @output = output
    end

    def resolve!
      unresolvable = []
      @candidates.each { |candidate| resolve_candidate(candidate, unresolvable) }
      raise_unresolvable(unresolvable) if unresolvable.any?
      @manifest
    end

    private

    def resolve_candidate(candidate, unresolvable)
      return if @manifest.repo_for(candidate[:name])
      return @manifest.add_mapping(name: candidate[:name], repo: candidate[:repo]) if candidate[:source_type] == :git

      interactive? ? resolve_interactively(candidate) : resolve_non_interactively(candidate, unresolvable)
    end

    def resolve_interactively(candidate)
      repo = prompt(candidate, infer_repo(candidate))
      if repo
        @manifest.add_mapping(name: candidate[:name], repo:)
      else
        @output.puts "  Skipping #{candidate[:name]}"
      end
    end

    def resolve_non_interactively(candidate, unresolvable)
      repo = infer_repo(candidate)
      if repo
        warn "Note: auto-inferred repo for #{candidate[:name]}: #{repo}"
        @manifest.add_mapping(name: candidate[:name], repo:)
      else
        unresolvable << candidate
      end
    end

    def infer_repo(candidate)
      remote = candidate[:remote].to_s
      if (match = remote.match(%r{rubygems\.pkg\.github\.com/([^/]+)}))
        "git@github.com:#{match[1]}/#{candidate[:name]}.git"
      end
    end

    def prompt(candidate, inferred)
      @output.print "\n  #{candidate[:name]} (from #{candidate[:remote]})"
      @output.print "\n  Repo URL#{prompt_hint(inferred)}: "
      parse_prompt_input(@input.gets&.strip, inferred)
    end

    def prompt_hint(inferred)
      inferred ? " [#{inferred}] (or \"#{SKIP_INPUT}\" to skip)" : " (blank to skip)"
    end

    def parse_prompt_input(input, inferred)
      return nil if input.nil? || input == SKIP_INPUT || (input.empty? && inferred.nil?)

      input.empty? ? inferred : input
    end

    def interactive?
      @input.respond_to?(:isatty) && @input.isatty
    end

    def raise_unresolvable(candidates)
      lines = candidates.map { |c| "  - #{c[:name]} (from #{c[:remote]})" }.join("\n")
      raise UnresolvableGemError,
            "Cannot resolve repo URLs non-interactively for:\n#{lines}\n\n" \
            "Run this command in a terminal to map these interactively, " \
            "or add them to your manifest manually."
    end
  end
end
