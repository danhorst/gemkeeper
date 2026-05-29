# frozen_string_literal: true

require "compact_index"
require "digest"
require "rack"

require_relative "compact_index_server/cache_store"
require_relative "compact_index_server/gem_index"
require_relative "compact_index_server/response_builder"
require_relative "compact_index_server/upload_handler"
require_relative "compact_index_server/upstream_cache"

module Gemkeeper
  # Rack application implementing the Bundler compact index protocol.
  # Delegates private gem state to GemIndex and upstream caching to UpstreamCache.
  class CompactIndexServer
    VALID_NAME = /\A[a-zA-Z0-9._-]+\z/
    RESOURCE_ROUTES = {
      info: %r{\A/info/([^/]+)\z},
      gem: %r{\A/gems/([^/]+\.gem)\z}
    }.freeze

    def initialize(gems_path:, cache_dir:)
      @index  = GemIndex.new(File.join(gems_path, "gems"))
      @cache  = UpstreamCache.new(cache_dir)
      @upload = UploadHandler.new(@index)
    end

    def call(env)
      req  = Rack::Request.new(env)
      path = req.path_info
      case [req.request_method, path]
      in ["GET", "/"]         then health
      in ["GET", "/names"]    then serve_names(req)
      in ["GET", "/versions"] then serve_versions(req)
      in ["POST", "/upload"]  then @upload.call(req)
      in ["GET", _]           then serve_resource(path, req)
      else not_found
      end
    end

    private

    # ── Routing ──────────────────────────────────────────────────────────────

    def serve_resource(path, req)
      type, name = match_resource(path)
      return not_found unless type
      return invalid_name unless VALID_NAME.match?(name)

      type == :info ? serve_info(name, req) : serve_gem_file(name)
    end

    def match_resource(path)
      RESOURCE_ROUTES.each do |type, pattern|
        match = path.match(pattern)
        return [type, match[1]] if match
      end
      nil
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
      gem = @index[gemname]
      gem ? serve_private_info(gem, req) : serve_upstream_info(gemname, req)
    rescue UpstreamUnavailableError
      upstream_unavailable
    end

    def serve_private_info(gem, req)
      body = CompactIndex.info(gem.versions)
      ResponseBuilder.new(req).index(body, Digest::SHA256.hexdigest(body))
    end

    def serve_upstream_info(gemname, req)
      result = @cache.info(gemname)
      result ? ResponseBuilder.new(req).index(result[:body], result[:etag]) : not_found
    end

    def serve_gem_file(filename)
      path = @index.gem_path(filename) || @cache.gem_binary(filename)
      path ? ResponseBuilder.file(path) : not_found
    rescue UpstreamUnavailableError
      upstream_unavailable
    end

    # ── HTTP response helpers ─────────────────────────────────────────────────

    def serve_index_file(file_path, etag, req)
      return upstream_unavailable unless file_path && File.exist?(file_path)

      ResponseBuilder.new(req).index(File.binread(file_path), etag)
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
