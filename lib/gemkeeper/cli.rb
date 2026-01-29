# frozen_string_literal: true

require "dry/cli"

module Gemkeeper
  module CLI
    extend Dry::CLI::Registry

    module Commands
      extend Dry::CLI::Registry
    end
  end
end

require_relative "cli/commands/version"
require_relative "cli/commands/sync"
require_relative "cli/commands/list"
require_relative "cli/commands/server/start"
require_relative "cli/commands/server/stop"
require_relative "cli/commands/server/status"
