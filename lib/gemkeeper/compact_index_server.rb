# frozen_string_literal: true

require "compact_index"
require "digest"
require "rack"
require "rubygems/package"
require "zlib"

require_relative "compact_index_server/cache_store"
require_relative "compact_index_server/gem_index"
require_relative "compact_index_server/upstream_cache"

module Gemkeeper
  # Rack application implementing the Bundler compact index protocol.
  # Delegates private gem state to GemIndex and upstream caching to UpstreamCache.
  class CompactIndexServer
    VALID_NAME = /\A[a-zA-Z0-9._-]+\z/

    def initialize(gems_path:, cache_dir:)
      @index = GemIndex.new(File.join(gems_path, "gems"))
      @cache = UpstreamCache.new(cache_dir)
    end

    def call(env)
      req  = Rack::Request.new(env)
      path = req.path_info
      case req.request_method
      when "GET"  then dispatch_get(path, req)
      when "POST" then dispatch_post(path, req)
      else not_found
      end
    end

    private

    # ── Routing ──────────────────────────────────────────────────────────────

    def dispatch_get(path, req)
      case path
      when "/"         then health
      when "/names"    then serve_names(req)
      when "/versions" then serve_versions(req)
      else dispatch_get_parameterized(path, req)
      end
    end

    def dispatch_post(path, req)
      return handle_upload(req) if path == "/upload"

      not_found
    end

    def dispatch_get_parameterized(path, req)
      if (match = path.match(%r{\A/info/([^/]+)\z}))
        gemname = match[1]
        return invalid_name unless VALID_NAME.match?(gemname)

        serve_info(gemname, req)
      elsif (match = path.match(%r{\A/gems/([^/]+\.gem)\z}))
        filename = match[1]
        return invalid_name unless VALID_NAME.match?(filename)

        serve_gem_file(filename)
      else
        not_found
      end
    end

    # ── Serving ───────────────────────────────────────────────────────────────

    def serve_names(req)
      result = @cache.merged_names(@index.keys)
      serve_index_file(result[:path], result[:etag], req)
    end

    def serve_versions(req)
      result = @cache.merged_versions(@index.values)
      serve_index_file(result[:path], result[:etag], req)
    end

    def serve_info(gemname, req)
      if (gem = @index[gemname])
        body = CompactIndex.info(gem.versions)
        serve_body(body, Digest::SHA256.hexdigest(body), req)
      else
        result = @cache.info(gemname)
        result ? serve_body(result[:body], result[:etag], req) : not_found
      end
    rescue UpstreamUnavailableError
      upstream_unavailable
    end

    def serve_gem_file(filename)
      path = @index.gem_path(filename) || @cache.gem_binary(filename)
      path ? send_file(path) : not_found
    rescue UpstreamUnavailableError
      upstream_unavailable
    end

    # ── Upload ────────────────────────────────────────────────────────────────

    def handle_upload(req)
      upload = req.params["file"]
      return [400, { "content-type" => "text/plain" }, ["Missing file parameter"]] unless upload

      tempfile_path = upload[:tempfile].path
      spec          = Gem::Package.new(tempfile_path).spec
      filename      = @index.add!(tempfile_path, spec)
      [201, { "content-type" => "text/plain" }, ["Uploaded #{filename}"]]
    rescue Errno::EEXIST
      [409, { "content-type" => "text/plain" }, ["Gem already exists"]]
    rescue Gem::Exception, Gem::Package::FormatError, Zlib::Error, TypeError, ArgumentError => error
      [422, { "content-type" => "text/plain" }, ["Invalid gem: #{error.message}"]]
    end

    # ── HTTP response helpers ─────────────────────────────────────────────────

    def serve_index_file(path, etag, req)
      return upstream_unavailable unless path && File.exist?(path)

      serve_body(File.binread(path), etag, req)
    end

    def serve_body(body, etag, req)
      quoted = %("#{etag}")
      return [304, { "etag" => quoted }, []] if req.env["HTTP_IF_NONE_MATCH"] == quoted

      apply_range(body, etag, req) || [200, index_headers(etag, body), [body]]
    end

    def apply_range(body, etag, req)
      range_header = req.env["HTTP_RANGE"]
      return nil unless range_header

      size  = body.bytesize
      match = range_header.match(/\Abytes=(\d+)-(\d*)\z/)
      return [416, { "content-range" => "bytes */#{size}" }, []] unless match

      start_byte = match[1].to_i
      return [416, { "content-range" => "bytes */#{size}" }, []] if start_byte >= size

      raw_end  = match[2]
      end_byte = raw_end.empty? ? size - 1 : [raw_end.to_i, size - 1].min
      partial  = body.byteslice(start_byte, end_byte - start_byte + 1)
      [206, index_headers(etag, body).merge("content-range" => "bytes #{start_byte}-#{end_byte}/#{size}"), [partial]]
    end

    def index_headers(etag, body)
      { "content-type" => "text/plain",
        "etag" => %("#{etag}"),
        "repr-digest" => "sha-256=:#{Digest::SHA256.base64digest(body)}:",
        "accept-ranges" => "bytes" }
    end

    def send_file(path)
      [200,
       { "content-type" => "application/octet-stream",
         "content-length" => File.size(path).to_s },
       File.open(path, "rb")]
    end

    def health       = [200, { "content-type" => "text/plain" }, ["OK"]]
    def not_found    = [404, { "content-type" => "text/plain" }, ["Not Found"]]
    def invalid_name = [400, { "content-type" => "text/plain" }, ["Invalid name"]]

    def upstream_unavailable
      [503, { "content-type" => "text/plain" },
       ["Upstream unavailable and no local cache. " \
        "Connect to the internet and run bundle install to warm the cache."]]
    end
  end
end
