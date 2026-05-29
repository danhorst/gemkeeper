# frozen_string_literal: true

require "digest"

module Gemkeeper
  class CompactIndexServer
    # Builds Rack responses for compact index payloads: conditional GET (ETag),
    # byte-range requests, and the digest/accept-ranges headers Bundler expects.
    class ResponseBuilder
      def self.file(path)
        [200,
         { "content-type" => "application/octet-stream",
           "content-length" => File.size(path).to_s },
         File.open(path, "rb")]
      end

      def initialize(req)
        @req = req
      end

      # 200 / 206 / 304 for an in-memory index body.
      def index(body, etag)
        quoted = %("#{etag}")
        return [304, { "etag" => quoted }, []] if @req.env["HTTP_IF_NONE_MATCH"] == quoted

        range(body, etag) || [200, index_headers(body, etag), [body]]
      end

      private

      def range(body, etag)
        header = @req.env["HTTP_RANGE"]
        return nil unless header

        size  = body.bytesize
        match = header.match(/\Abytes=(\d+)-(\d*)\z/)
        return unsatisfiable(size) unless match

        start_byte = match[1].to_i
        return unsatisfiable(size) if start_byte >= size

        partial(body, etag, start_byte, match[2], size)
      end

      def partial(body, etag, start_byte, raw_end, size)
        end_byte = raw_end.empty? ? size - 1 : [raw_end.to_i, size - 1].min
        slice    = body.byteslice(start_byte, end_byte - start_byte + 1)
        [206,
         index_headers(body, etag).merge("content-range" => "bytes #{start_byte}-#{end_byte}/#{size}"),
         [slice]]
      end

      def unsatisfiable(size) = [416, { "content-range" => "bytes */#{size}" }, []]

      def index_headers(body, etag)
        { "content-type" => "text/plain",
          "etag" => %("#{etag}"),
          "repr-digest" => "sha-256=:#{Digest::SHA256.base64digest(body)}:",
          "accept-ranges" => "bytes" }
      end
    end
  end
end
