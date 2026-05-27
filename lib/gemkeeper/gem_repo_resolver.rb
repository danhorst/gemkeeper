# frozen_string_literal: true

module Gemkeeper
  # Resolves gem candidates (from lockfile sources) to git repo URLs.
  # GIT-sourced gems are added automatically; private gem registry entries
  # are inferred where possible (GitHub Packages) or prompted interactively.
  class GemRepoResolver
    def initialize(candidates:, manifest:, input: $stdin, output: $stdout)
      @candidates = candidates
      @manifest = manifest
      @input = input
      @output = output
    end

    def resolve!
      unresolvable = []

      @candidates.each do |candidate|
        name = candidate[:name]
        next if @manifest.repo_for(name)

        if candidate[:source_type] == :git
          @manifest.add_mapping(name:, repo: candidate[:repo])
        else
          repo = resolve_private_gem(candidate)
          if repo
            @manifest.add_mapping(name:, repo:)
          else
            unresolvable << candidate
          end
        end
      end

      raise_unresolvable(unresolvable) if unresolvable.any?
      @manifest
    end

    private

    def resolve_private_gem(candidate)
      inferred = infer_repo(candidate)

      if interactive?
        prompt(candidate, inferred)
      elsif inferred
        warn "Note: auto-inferred repo for #{candidate[:name]}: #{inferred}"
        inferred
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
      @output.print "\n  Repo URL"
      @output.print " [#{inferred}]" if inferred
      @output.print ": "
      input = @input.gets&.strip
      input = inferred if input.nil? || input.empty?
      input
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
