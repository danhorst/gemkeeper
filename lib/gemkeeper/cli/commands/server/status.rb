# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      module Server
        class Status < Dry::CLI::Command
          desc "Check Geminabox server status"

          option :config, type: :string, desc: "Path to config file"

          def call(**options)
            config = Configuration.load(options[:config])
            manager = ServerManager.new(config)
            status = manager.status

            if status[:running]
              puts "Geminabox server is running"
              puts "  PID: #{status[:pid]}"
              puts "  URL: #{status[:url]}"
            else
              puts "Geminabox server is not running"
            end
          end
        end
      end
    end

    register "server status", Commands::Server::Status
  end
end
