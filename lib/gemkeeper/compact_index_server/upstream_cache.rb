# frozen_string_literal: true

require "compact_index"
require "net/http"
require "zlib"

require_relative "cache_store"

module Gemkeeper
  class CompactIndexServer
    # Fetches and caches compact index responses from RubyGems.org.
    # Generates merged index files that combine upstream data with private gems.
    class UpstreamCache
      RUBYGEMS_HOST = "rubygems.org"
      VERSIONS_TTL  = 1800 # 30 minutes
      INFO_TTL      = 3600 # 60 minutes
      OPEN_TIMEOUT  = 5
      READ_TIMEOUT  = 10

      def initialize(cache_dir)
        @store         = CacheStore.new(File.join(cache_dir, "rubygems_cache"))
        @versions_etag = @store.etag_for(:versions_merged)
        @names_etag    = @store.etag_for(:names_merged)
      end

      # Returns {path:, etag:} for the merged /versions file.
      def merged_versions(private_gems)
        refresh_upstream(:versions, "/versions", VERSIONS_TTL)
        regenerate_versions_merged(private_gems)
        { path: @store.path(:versions_merged), etag: @versions_etag }
      end

      # Returns {path:, etag:} for the merged /names file.
      def merged_names(private_names)
        refresh_upstream(:names, "/names", INFO_TTL)
        regenerate_names_merged(private_names)
        { path: @store.path(:names_merged), etag: @names_etag }
      end

      # Returns {body:, etag:} or nil (not found).
      # Raises UpstreamUnavailableError when unreachable with no cache.
      def info(gemname)
        info_path = @store.path("info/#{gemname}")
        meta      = @store.read_meta("info/#{gemname}")

        return cached_entry(info_path, meta) if info_cache_fresh?(info_path, meta)

        fetch_and_cache_info(gemname, info_path, meta)
      rescue UpstreamUnavailableError
        raise unless File.exist?(info_path)

        cached_entry(info_path, meta)
      end

      # Returns a local path to the gem binary, or nil (not found).
      # Raises UpstreamUnavailableError when unreachable with no cached copy.
      def gem_binary(filename)
        Gem.path.each do |gp|
          sys = File.join(gp, "cache", filename)
          return sys if File.exist?(sys)
        end

        cached = @store.path("gems/#{filename}")
        return cached if File.exist?(cached)

        fetch_and_cache_gem(filename, cached)
      end

      private

      def refresh_upstream(key, upstream_path, ttl)
        body_path = @store.path(key)
        meta      = @store.read_meta(key.to_s)
        return if meta && !@store.ttl_expired?(meta, ttl) && File.exist?(body_path)

        result = fetch_upstream(upstream_path, meta&.fetch("etag", nil))
        if result == :not_modified
          @store.write_meta(key.to_s, etag: meta["etag"])
        else
          @store.atomic_write(body_path, result[:body])
          @store.write_meta(key.to_s, etag: result[:etag])
        end
      rescue UpstreamUnavailableError
        nil # regeneration proceeds with whatever is cached
      end

      def regenerate_versions_merged(private_gems)
        versions_path = @store.path(:versions)
        unless File.exist?(versions_path)
          @store.atomic_write(versions_path,
                              "created_at: #{Time.now.utc.iso8601}\n---\n")
        end
        merged = CompactIndex.versions(CompactIndex::VersionsFile.new(versions_path), private_gems)
        @store.atomic_write(@store.path(:versions_merged), merged)
        @versions_etag = Digest::SHA256.hexdigest(merged)
      end

      def regenerate_names_merged(private_names)
        names_path = @store.path(:names)
        upstream   = if File.exist?(names_path)
                       File.read(names_path).lines.map(&:strip).reject { |line| line.empty? || line == "---" }
                     else
                       []
                     end
        merged_body = CompactIndex.names((upstream + private_names).uniq.sort)
        @store.atomic_write(@store.path(:names_merged), merged_body)
        @names_etag = Digest::SHA256.hexdigest(merged_body)
      end

      # ── Info cache ────────────────────────────────────────────────────────

      def fetch_and_cache_info(gemname, info_path, meta)
        result = fetch_upstream("/info/#{gemname}", meta&.fetch("etag", nil))

        if result == :not_modified
          @store.write_meta("info/#{gemname}", etag: meta["etag"])
          cached_entry(info_path, meta)
        elsif result[:status] == 200
          body = result[:body]
          etag = result[:etag] || Digest::SHA256.hexdigest(body)
          @store.atomic_write(info_path, body)
          @store.write_meta("info/#{gemname}", etag: etag)
          { body: body, etag: etag }
        end
      end

      def info_cache_fresh?(info_path, meta) = File.exist?(info_path) && meta && !@store.ttl_expired?(meta, INFO_TTL)

      def cached_entry(path, meta)
        body = File.binread(path)
        { body:, etag: meta&.fetch("etag", nil) || Digest::SHA256.hexdigest(body) }
      end

      def fetch_and_cache_gem(filename, cache_path)
        result = fetch_upstream("/gems/#{filename}", nil)
        return nil unless result.is_a?(Hash) && result[:status] == 200

        @store.atomic_write(cache_path, result[:body]) && cache_path
      end

      # ── Upstream HTTP ─────────────────────────────────────────────────────

      def fetch_upstream(path, if_none_match = nil)
        uri = URI("https://#{RUBYGEMS_HOST}#{path}")
        req = Net::HTTP::Get.new(uri)
        req["If-None-Match"]   = if_none_match if if_none_match
        req["Accept-Encoding"] = "gzip"

        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                            open_timeout: OPEN_TIMEOUT,
                                            read_timeout: READ_TIMEOUT) do |http|
          res         = http.request(req)
          status_code = res.code.to_i
          case status_code
          when 304 then :not_modified
          when 200 then { status: 200, body: decompress(res.body.to_s, res["Content-Encoding"]), etag: res["ETag"] }
          else          { status: status_code, body: res.body.to_s, etag: nil }
          end
        end
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
             Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError => error
        raise UpstreamUnavailableError, error.message
      end

      def decompress(body, encoding)
        return body unless encoding&.include?("gzip")

        Zlib::GzipReader.new(StringIO.new(body)).read
      rescue Zlib::Error
        body
      end
    end
  end
end
