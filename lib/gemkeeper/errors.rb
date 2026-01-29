# frozen_string_literal: true

module Gemkeeper
  class Error < StandardError; end

  class ConfigurationError < Error; end
  class ConfigFileNotFoundError < ConfigurationError; end
  class InvalidConfigError < ConfigurationError; end

  class GitError < Error; end
  class CloneError < GitError; end
  class CheckoutError < GitError; end

  class BuildError < Error; end
  class GemspecNotFoundError < BuildError; end

  class UploadError < Error; end

  class ServerError < Error; end
  class ServerAlreadyRunningError < ServerError; end
  class ServerNotRunningError < ServerError; end
end
