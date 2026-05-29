# frozen_string_literal: true

require "net/http"
require "zlib"

require_relative "response"

module Gemkeeper
  class CompactIndexServer
    # HTTP client for RubyGems.org compact index endpoints.
    # Speaks conditional GET (ETag) and gzip; raises UpstreamUnavailableError
    # on any network failure so callers can fall back to cache.
    class RubygemsClient
      HOST         = "rubygems.org"
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10

      # Returns :not_modified, or {status:, body:, etag:}.
      def get(path, if_none_match = nil)
        uri = URI("https://#{HOST}#{path}")
        req = build_request(uri, if_none_match)

        Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                            open_timeout: OPEN_TIMEOUT,
                                            read_timeout: READ_TIMEOUT) do |http|
          interpret(http.request(req))
        end
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
             Net::OpenTimeout, Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError => error
        raise UpstreamUnavailableError, error.message
      end

      private

      def build_request(uri, if_none_match)
        req = Net::HTTP::Get.new(uri)
        req["If-None-Match"]   = if_none_match if if_none_match
        req["Accept-Encoding"] = "gzip"
        req
      end

      def interpret(res)
        case res.code.to_i
        when 304 then Response.new(304, nil, nil)
        when 200 then Response.new(200, decompress(res.body.to_s, res["Content-Encoding"]), res["ETag"])
        else          Response.new(res.code.to_i, res.body.to_s, nil)
        end
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
