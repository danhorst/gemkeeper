# frozen_string_literal: true

require "rubygems/package"
require "zlib"

module Gemkeeper
  class CompactIndexServer
    # Handles POST /upload: reads the multipart gem file, parses its spec,
    # and adds it to the index. Maps failures to compact-index HTTP responses.
    class UploadHandler
      def initialize(index)
        @index = index
      end

      def call(req)
        upload = req.params["file"]
        return text(400, "Missing file parameter") unless upload

        text(201, "Uploaded #{add(upload[:tempfile].path)}")
      rescue Errno::EEXIST
        text(409, "Gem already exists")
      rescue Gem::Exception, Gem::Package::FormatError, Zlib::Error, TypeError, ArgumentError => error
        text(422, "Invalid gem: #{error.message}")
      end

      private

      def add(tempfile_path)
        spec = Gem::Package.new(tempfile_path).spec
        @index.add(tempfile_path, spec)
      end

      def text(status, message) = [status, { "content-type" => "text/plain" }, [message]]
    end
  end
end
