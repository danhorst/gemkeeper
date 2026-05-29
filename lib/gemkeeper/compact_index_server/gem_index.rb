# frozen_string_literal: true

require "compact_index"
require "digest"
require "fileutils"
require "rubygems/package"

module Gemkeeper
  class CompactIndexServer
    # Builds and maintains the in-memory index of privately-hosted gems.
    # Scans gems_dir on construction and after each successful upload.
    class GemIndex
      def initialize(gems_dir)
        @gems_dir = gems_dir
        @gems     = {}
        FileUtils.mkdir_p(@gems_dir)
        rebuild!
      end

      def [](name)   = @gems[name]
      def keys       = @gems.keys
      def values     = @gems.values

      def gem_path(filename)
        path = File.join(@gems_dir, filename)
        File.exist?(path) ? path : nil
      end

      # Copies source_path into gems_dir, derives the filename from spec, and rebuilds.
      # Raises Errno::EEXIST if the gem already exists. Returns the target filename.
      def add!(source_path, spec)
        filename = gem_filename(spec)
        target   = File.join(@gems_dir, filename)
        raise Errno::EEXIST, target if File.exist?(target)

        tmp = "#{target}.tmp.#{Process.pid}.#{Thread.current.object_id}"
        FileUtils.cp(source_path, tmp)
        File.rename(tmp, target)
        rebuild!
        filename
      end

      def rebuild!
        gems = {}
        Dir.glob(File.join(@gems_dir, "*.gem")).each do |gem_file|
          spec = Gem::Package.new(gem_file).spec
          name = spec.name
          (gems[name] ||= CompactIndex::Gem.new(name, [])).versions << gem_version_for(spec, gem_file)
        rescue StandardError => error
          warn "gemkeeper: skipping #{File.basename(gem_file)}: #{error.message}"
        end

        gems.each_value do |gem|
          versions = gem.versions
          versions.last.info_checksum = Digest::MD5.hexdigest(CompactIndex.info(versions))
        end

        @gems = gems
      end

      private

      def gem_filename(spec)
        name     = spec.name
        version  = spec.version
        platform = spec.platform.to_s
        if platform.empty? || platform == "ruby"
          "#{name}-#{version}.gem"
        else
          "#{name}-#{version}-#{platform}.gem"
        end
      end

      def gem_version_for(spec, gem_file)
        deps = (spec.runtime_dependencies || []).map do |dep|
          CompactIndex::Dependency.new(dep.name, dep.requirement.to_s)
        end
        CompactIndex::GemVersion.new(
          spec.version.to_s,
          spec.platform.to_s,
          Digest::SHA256.file(gem_file).hexdigest,
          nil,
          deps,
          spec.required_ruby_version&.to_s,
          spec.required_rubygems_version&.to_s
        )
      end
    end
  end
end
