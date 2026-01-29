# frozen_string_literal: true

require "faraday"
require "faraday/multipart"

module Gemkeeper
  class GemUploader
    attr_reader :geminabox_url

    def initialize(geminabox_url)
      @geminabox_url = geminabox_url
    end

    def upload(gem_path)
      raise UploadError, "Gem file not found: #{gem_path}" unless File.exist?(gem_path)

      response = connection.post("/upload") do |req|
        req.body = {
          file: Faraday::Multipart::FilePart.new(
            gem_path,
            "application/octet-stream",
            File.basename(gem_path)
          )
        }
      end

      handle_response(response, gem_path)
    end

    def list_gems
      response = connection.get("/api/v1/gems.json")

      raise UploadError, "Failed to list gems: #{response.status} #{response.body}" unless response.success?

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise UploadError, "Invalid JSON response: #{e.message}"
    rescue Faraday::Error => e
      raise UploadError, "Connection error: #{e.message}"
    end

    private

    def connection
      @connection ||= Faraday.new(url: @geminabox_url) do |f|
        f.request :multipart
        f.request :url_encoded
        f.adapter Faraday::Adapter::NetHttp
      end
    end

    def handle_response(response, gem_path)
      case response.status
      when 200, 201, 302
        { success: true, message: "Uploaded #{File.basename(gem_path)}" }
      when 409
        { success: true, message: "#{File.basename(gem_path)} already exists", skipped: true }
      else
        raise UploadError, "Upload failed (#{response.status}): #{response.body}"
      end
    rescue Faraday::Error => e
      raise UploadError, "Connection error: #{e.message}"
    end
  end
end
