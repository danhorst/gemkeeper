# frozen_string_literal: true

require "digest"
require "rubygems"

module Gemkeeper
  class CompactIndexServer
    # Per-gem caching of /info documents and .gem binaries from RubyGems.org.
    # Serves from the local RubyGems cache, then the disk cache, then upstream.
    class GemCache
      INFO_TTL = 3600 # 60 minutes

      def initialize(store, client)
        @store  = store
        @client = client
      end

      # Returns {body:, etag:} or nil (not found).
      # Raises UpstreamUnavailableError when unreachable with no cache.
      def info(gemname)
        path = @store.path("info/#{gemname}")
        meta = @store.read_meta("info/#{gemname}")
        return cached_entry(path, meta) if fresh?(path, meta)

        fetch_info(gemname, path, meta)
      rescue UpstreamUnavailableError
        raise unless File.exist?(path)

        cached_entry(path, meta)
      end

      # Returns a local path to the gem binary, or nil (not found).
      # Raises UpstreamUnavailableError when unreachable with no cached copy.
      def binary(filename)
        system_gem_path(filename) ||
          disk_cache_path(filename) ||
          fetch_binary(filename, @store.path("gems/#{filename}"))
      end

      private

      def system_gem_path(filename)
        Gem.path.each do |gem_path|
          candidate = File.join(gem_path, "cache", filename)
          return candidate if File.exist?(candidate)
        end
        nil
      end

      def disk_cache_path(filename)
        path = @store.path("gems/#{filename}")
        File.exist?(path) ? path : nil
      end

      def fetch_info(gemname, path, meta)
        response = @client.get("/info/#{gemname}", meta&.etag)
        return store_info(gemname, path, response) unless response.not_modified?

        @store.write_meta("info/#{gemname}", etag: meta.etag)
        cached_entry(path, meta)
      end

      def store_info(gemname, path, response)
        return nil unless response.success?

        body = response.body
        etag = response.etag || Digest::SHA256.hexdigest(body)
        @store.atomic_write(path, body)
        @store.write_meta("info/#{gemname}", etag: etag)
        { body: body, etag: etag }
      end

      def fetch_binary(filename, cache_path)
        response = @client.get("/gems/#{filename}", nil)
        return nil unless response.success?

        @store.atomic_write(cache_path, response.body) && cache_path
      end

      def fresh?(path, meta) = File.exist?(path) && meta && !meta.expired?(INFO_TTL)

      def cached_entry(path, meta)
        body = File.binread(path)
        { body:, etag: meta&.etag || Digest::SHA256.hexdigest(body) }
      end
    end
  end
end
