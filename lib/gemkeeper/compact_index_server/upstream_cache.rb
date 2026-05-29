# frozen_string_literal: true

require_relative "cache_store"
require_relative "gem_cache"
require_relative "index_merger"
require_relative "rubygems_client"

module Gemkeeper
  class CompactIndexServer
    # Composition root for upstream RubyGems.org caching. Wires a shared on-disk
    # store and HTTP client into the merged-index and per-gem cache collaborators.
    class UpstreamCache
      def initialize(cache_dir)
        store   = CacheStore.new(File.join(cache_dir, "rubygems_cache"))
        client  = RubygemsClient.new
        @merger = IndexMerger.new(store, client)
        @gems   = GemCache.new(store, client)
      end

      def merged_versions(private_gems) = @merger.versions(private_gems)
      def merged_names(private_names)   = @merger.names(private_names)
      def info(gemname)                 = @gems.info(gemname)
      def gem_binary(filename)          = @gems.binary(filename)
    end
  end
end
