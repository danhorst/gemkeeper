# frozen_string_literal: true

require "compact_index"
require "digest"
require "time"

module Gemkeeper
  class CompactIndexServer
    # Generates the merged /versions and /names index files, combining upstream
    # RubyGems.org data (refreshed on a TTL) with the locally-hosted private gems.
    class IndexMerger
      VERSIONS_TTL = 1800 # 30 minutes
      NAMES_TTL    = 3600 # 60 minutes

      def initialize(store, client)
        @store         = store
        @client        = client
        @versions_etag = store.etag_for(:versions_merged)
        @names_etag    = store.etag_for(:names_merged)
      end

      # Returns {path:, etag:} for the merged /versions file.
      def versions(private_gems)
        refresh(:versions, "/versions", VERSIONS_TTL)
        regenerate_versions(private_gems)
        { path: @store.path(:versions_merged), etag: @versions_etag }
      end

      # Returns {path:, etag:} for the merged /names file.
      def names(private_names)
        refresh(:names, "/names", NAMES_TTL)
        regenerate_names(private_names)
        { path: @store.path(:names_merged), etag: @names_etag }
      end

      private

      def refresh(key, upstream_path, ttl)
        meta = @store.read_meta(key.to_s)
        return if meta && !meta.expired?(ttl) && File.exist?(@store.path(key))

        apply(key, meta, @client.get(upstream_path, meta&.etag))
      rescue UpstreamUnavailableError
        nil # regeneration proceeds with whatever is cached
      end

      def apply(key, meta, response)
        if response.not_modified?
          etag = meta.etag
        else
          @store.atomic_write(@store.path(key), response.body)
          etag = response.etag
        end
        @store.write_meta(key.to_s, etag: etag)
      end

      def regenerate_versions(private_gems)
        versions_path = @store.path(:versions)
        unless File.exist?(versions_path)
          @store.atomic_write(versions_path, "created_at: #{Time.now.utc.iso8601}\n---\n")
        end
        merged = CompactIndex.versions(CompactIndex::VersionsFile.new(versions_path), private_gems)
        @store.atomic_write(@store.path(:versions_merged), merged)
        @versions_etag = Digest::SHA256.hexdigest(merged)
      end

      def regenerate_names(private_names)
        merged = CompactIndex.names((upstream_names + private_names).uniq.sort)
        @store.atomic_write(@store.path(:names_merged), merged)
        @names_etag = Digest::SHA256.hexdigest(merged)
      end

      def upstream_names
        names_path = @store.path(:names)
        return [] unless File.exist?(names_path)

        File.read(names_path).lines.map(&:strip).reject { |line| line.empty? || line == "---" }
      end
    end
  end
end
