# frozen_string_literal: true

module Gemkeeper
  # Builds or updates a manifest from a Gemfile.lock, tracking what changed.
  class ManifestBuilder
    Result = Struct.new(:manifest, :candidates, :added_count, :skipped_count, :already_mapped_count,
                        keyword_init: true) do
      def any_changes?
        added_count.positive?
      end

      def empty?
        candidates.empty?
      end
    end

    def self.build(lockfile_path:, manifest:, input: $stdin, output: $stdout)
      new(lockfile_path:, manifest:).build!(input:, output:)
    end

    def initialize(lockfile_path:, manifest:)
      @lockfile_path = lockfile_path
      @manifest = manifest
    end

    def build!(input: $stdin, output: $stdout)
      candidates = LockfileParser.internal_sources(@lockfile_path)
      already_mapped_count = candidates.count { |c| @manifest.repo_for(c[:name]) }
      before_size = @manifest.gems.size

      GemRepoResolver.new(candidates:, manifest: @manifest, input:, output:).resolve! unless candidates.empty?

      added_count = @manifest.gems.size - before_size
      skipped_count = candidates.size - already_mapped_count - added_count

      Result.new(manifest: @manifest, candidates:, added_count:, skipped_count:, already_mapped_count:)
    end
  end
end
