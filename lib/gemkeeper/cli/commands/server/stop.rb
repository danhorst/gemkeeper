# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      module Server
        class Stop < Dry::CLI::Command
          desc "Stop the Geminabox server"

          option :config, type: :string, desc: "Path to config file"

          def call(**options)
            config = Configuration.load(options[:config])
            manager = ServerManager.new(config)
            manager.stop

            puts "Geminabox server stopped"
          rescue ServerNotRunningError => e
            warn "Error: #{e.message}"
            exit 1
          rescue ServerError => e
            warn "Error stopping server: #{e.message}"
            exit 1
          end
        end
      end
    end

    register "server stop", Commands::Server::Stop
  end
end
