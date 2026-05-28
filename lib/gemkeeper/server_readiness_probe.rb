# frozen_string_literal: true

require "net/http"

module Gemkeeper
  # Polls the server's HTTP endpoint until it responds or a timeout is reached.
  class ServerReadinessProbe
    def initialize(url)
      @uri = URI(url)
    end

    def wait(timeout: 10)
      (timeout / 0.5).ceil.times do
        return true if responding?

        sleep 0.5
      end
      raise ServerError, "Server failed to start within #{timeout} seconds"
    end

    private

    def responding?
      response = Net::HTTP.get_response(@uri)
      response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError
      false
    end
  end
end
