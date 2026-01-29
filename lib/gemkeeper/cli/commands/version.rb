# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      class Version < Dry::CLI::Command
        desc "Print version"

        def call(*)
          puts "gemkeeper #{Gemkeeper::VERSION}"
        end
      end
    end

    register "version", Commands::Version, aliases: ["-v", "--version"]
  end
end
