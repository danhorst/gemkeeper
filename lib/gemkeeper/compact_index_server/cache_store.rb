# frozen_string_literal: true

require "digest"
require "fileutils"
require "yaml"

require_relative "cache_meta"

module Gemkeeper
  class CompactIndexServer
    # Handles on-disk cache I/O: atomic writes, sidecar metadata, TTL checks.
    # All paths are resolved relative to a base directory.
    class CacheStore
      ENTRIES = {
        versions: "versions",
        versions_merged: "versions.merged",
        versions_meta: "versions.meta",
        names: "names",
        names_merged: "names.merged",
        names_meta: "names.meta"
      }.freeze

      def initialize(base_dir)
        @base_dir = base_dir
        FileUtils.mkdir_p([base_dir, File.join(base_dir, "info"), File.join(base_dir, "gems")])
      end

      def path(key_or_filename)
        filename = ENTRIES.fetch(key_or_filename, key_or_filename)
        File.join(@base_dir, filename.to_s)
      end

      def read_meta(filename)
        full_path = File.join(@base_dir, "#{filename}.meta")
        return nil unless File.exist?(full_path)

        CacheMeta.load(YAML.safe_load_file(full_path))
      rescue StandardError
        nil
      end

      def write_meta(filename, etag:)
        meta = CacheMeta.new(etag, Time.now.utc.iso8601)
        atomic_write(File.join(@base_dir, "#{filename}.meta"), meta.to_h.to_yaml)
      end

      def atomic_write(full_path, content)
        tmp = "#{full_path}.tmp.#{Process.pid}.#{Thread.current.object_id}"
        File.binwrite(tmp, content)
        File.rename(tmp, full_path)
      rescue StandardError
        File.unlink(tmp) if tmp && File.exist?(tmp)
        raise
      end

      def etag_for(key)
        full_path = path(key)
        return nil unless File.exist?(full_path)

        Digest::SHA256.hexdigest(File.binread(full_path))
      end
    end
  end
end
