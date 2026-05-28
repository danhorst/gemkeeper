# frozen_string_literal: true

require "faraday"
require "faraday/multipart"

module Gemkeeper
  # Encapsulates Geminabox's HTTP API so callers never construct multipart requests directly.
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
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError
      raise ServerNotReachableError,
            "Geminabox server is not reachable at #{@geminabox_url} — " \
            "run 'gemkeeper server start' or check 'gemkeeper server status'"
    end

    def reachable?
      connection.get("/")
      true
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError
      false
    end

    def list_gems
      response = connection.get("/api/v1/gems.json")

      body = response.body
      raise UploadError, "Failed to list gems: #{response.status} #{body}" unless response.success?

      JSON.parse(body)
    rescue JSON::ParserError => parse_error
      raise UploadError, "Invalid JSON response: #{parse_error.message}"
    rescue Faraday::Error => connection_error
      raise UploadError, "Connection error: #{connection_error.message}"
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
      status   = response.status
      gem_name = File.basename(gem_path)
      case status
      when 200, 201, 302
        { success: true, message: "Uploaded #{gem_name}" }
      when 409
        { success: true, message: "#{gem_name} already exists", skipped: true }
      else
        raise UploadError, "Upload failed (#{status}): #{response.body}"
      end
    rescue Faraday::Error => connection_error
      raise UploadError, "Connection error: #{connection_error.message}"
    end
  end
end
