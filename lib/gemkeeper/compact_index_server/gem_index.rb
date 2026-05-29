# frozen_string_literal: true

require "compact_index"
require "digest"
require "fileutils"
require "rubygems/package"

require_relative "spec_mapper"

module Gemkeeper
  class CompactIndexServer
    # Builds and maintains the in-memory index of privately-hosted gems.
    # Scans gems_dir on construction and after each successful upload.
    class GemIndex
      def initialize(gems_dir)
        @gems_dir = gems_dir
        @gems     = {}
        FileUtils.mkdir_p(@gems_dir)
        rebuild
      end

      def [](name)   = @gems[name]
      def keys       = @gems.keys
      def values     = @gems.values

      # True when the private store holds this exact name and bare-semver version.
      def serves?(name, version)
        gem = @gems[name]
        gem ? gem.versions.any? { |gem_version| gem_version.number == version } : false
      end

      def gem_path(filename)
        path = File.join(@gems_dir, filename)
        File.exist?(path) ? path : nil
      end

      # Copies source_path into gems_dir, derives the filename from spec, and rebuilds.
      # Raises Errno::EEXIST if the gem already exists. Returns the target filename.
      def add(source_path, spec)
        filename = SpecMapper.filename(spec)
        target   = File.join(@gems_dir, filename)
        raise Errno::EEXIST, target if File.exist?(target)

        copy_into_place(source_path, target)
        rebuild
        filename
      end

      def rebuild
        gems = {}
        Dir.glob(File.join(@gems_dir, "*.gem")).each { |gem_file| index_gem(gems, gem_file) }
        gems.each_value { |gem| stamp_checksum(gem) }
        @gems = gems
      end

      private

      def index_gem(gems, gem_file)
        spec = Gem::Package.new(gem_file).spec
        name = spec.name
        (gems[name] ||= CompactIndex::Gem.new(name, [])).versions << SpecMapper.gem_version(spec, gem_file)
      rescue StandardError => error
        warn "gemkeeper: skipping #{File.basename(gem_file)}: #{error.message}"
      end

      def stamp_checksum(gem)
        versions = gem.versions
        versions.last.info_checksum = Digest::MD5.hexdigest(CompactIndex.info(versions))
      end

      def copy_into_place(source_path, target)
        tmp = "#{target}.tmp.#{Process.pid}.#{Thread.current.object_id}"
        FileUtils.cp(source_path, tmp)
        File.rename(tmp, target)
      end
    end
  end
end
