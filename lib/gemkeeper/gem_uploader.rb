# frozen_string_literal: true

require "faraday"
require "faraday/multipart"

module Gemkeeper
  # Encapsulates the Gemkeeper server's upload HTTP API so callers never construct multipart requests directly.
  class GemUploader
    attr_reader :server_url

    def initialize(server_url)
      @server_url = server_url
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
      not_reachable!
    end

    # True when the running server's private store already serves name@version.
    # Hits the private-store endpoint, never /info, so a public gem can't fool it.
    def serves?(name, version)
      status = connection.get("/gemkeeper/has/#{name}/#{version}").status
      case status
      when 200 then true
      when 404 then false
      else raise ServerError, "Unexpected status #{status} checking #{name} #{version} on #{@server_url}"
      end
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError
      not_reachable!
    end

    def reachable?
      connection.get("/")
      true
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError
      false
    end

    def list_gems
      raise NotImplementedError, "list_gems is not supported by CompactIndexServer; use gemkeeper list instead"
    end

    private

    def not_reachable!
      raise ServerNotReachableError,
            "Gemkeeper server is not reachable at #{@server_url} — " \
            "run 'gemkeeper server start' or check 'gemkeeper server status'"
    end

    def connection
      @connection ||= Faraday.new(url: @server_url) do |f|
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
