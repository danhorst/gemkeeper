# frozen_string_literal: true

require "compact_index"
require "digest"

module Gemkeeper
  class CompactIndexServer
    # Maps a Gem::Specification to the compact-index representations the index is
    # built from: the on-disk gem filename and a CompactIndex::GemVersion entry.
    module SpecMapper
      module_function

      def filename(spec)
        platform = spec.platform.to_s
        suffix   = platform.empty? || platform == "ruby" ? "" : "-#{platform}"
        "#{spec.name}-#{spec.version}#{suffix}.gem"
      end

      def gem_version(spec, gem_file)
        CompactIndex::GemVersion.new(
          spec.version.to_s,
          spec.platform.to_s,
          Digest::SHA256.file(gem_file).hexdigest,
          nil,
          dependencies(spec),
          spec.required_ruby_version&.to_s,
          spec.required_rubygems_version&.to_s
        )
      end

      def dependencies(spec)
        (spec.runtime_dependencies || []).map do |dep|
          CompactIndex::Dependency.new(dep.name, dep.requirement.to_s)
        end
      end
    end
  end
end
