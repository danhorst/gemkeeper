# frozen_string_literal: true

require "time"

module Gemkeeper
  class CompactIndexServer
    # The sidecar metadata for a cached upstream document: its ETag and when it
    # was fetched. Knows whether it has aged past a TTL and how to serialize.
    class CacheMeta
      attr_reader :etag

      def self.load(hash)
        return nil unless hash

        new(hash["etag"], hash["fetched_at"])
      end

      def initialize(etag, fetched_at)
        @etag       = etag
        @fetched_at = fetched_at
      end

      def expired?(ttl)
        return true unless @fetched_at

        Time.now - Time.parse(@fetched_at.to_s) > ttl
      rescue ArgumentError
        true
      end

      def to_h = { "etag" => @etag, "fetched_at" => @fetched_at }
    end
  end
end
