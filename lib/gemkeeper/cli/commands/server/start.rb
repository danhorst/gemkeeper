# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      module Server
        class Start < Dry::CLI::Command
          desc "Start the Geminabox server"

          option :port, type: :integer, desc: "Port to run server on"
          option :config, type: :string, desc: "Path to config file"
          option :foreground, type: :boolean, default: false, aliases: ["-f"],
                              desc: "Run in foreground (don't daemonize)"

          def call(**options)
            config = Configuration.load(options[:config])
            config = override_port(config, options[:port]) if options[:port]

            manager = ServerManager.new(config)

            if options[:foreground]
              puts "Starting Geminabox server at #{config.geminabox_url}"
              puts "Press Ctrl+C to stop"
              manager.start_foreground
            else
              manager.start
              puts "Geminabox server started at #{config.geminabox_url}"
              puts "PID: #{File.read(config.pid_file).strip}"
            end
          rescue ServerAlreadyRunningError => e
            warn "Error: #{e.message}"
            exit 1
          rescue ServerError => e
            warn "Error starting server: #{e.message}"
            exit 1
          rescue Interrupt
            puts "\nShutting down..."
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
