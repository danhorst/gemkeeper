# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      module Server
        class Start < Dry::CLI::Command
          desc "Start the Geminabox server"

          option :port, type: :integer, desc: "Port to run server on"
          option :config, type: :string, desc: "Path to config file"

          def call(**options)
            config = Configuration.load(options[:config])
            config = override_port(config, options[:port]) if options[:port]

            manager = ServerManager.new(config)
            manager.start

            puts "Geminabox server started at #{config.geminabox_url}"
            puts "PID: #{File.read(config.pid_file).strip}"
          rescue ServerAlreadyRunningError => e
            warn "Error: #{e.message}"
            exit 1
          rescue ServerError => e
            warn "Error starting server: #{e.message}"
            exit 1
          end

          private

          def override_port(config, port)
            config.instance_variable_set(:@port, port)
            config
          end
        end
      end
    end

    register "server start", Commands::Server::Start
  end
end
