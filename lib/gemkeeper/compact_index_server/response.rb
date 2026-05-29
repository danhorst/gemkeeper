# frozen_string_literal: true

module Gemkeeper
  class CompactIndexServer
    # Outcome of a compact-index request: a not-modified marker (304) or a
    # body+etag (200), or a non-success status. Callers ask, never inspect.
    Response = Struct.new(:status, :body, :etag) do
      def not_modified? = status == 304
      def success?      = status == 200
    end
  end
end
