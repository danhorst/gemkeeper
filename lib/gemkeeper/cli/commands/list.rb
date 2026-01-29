# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      class List < Dry::CLI::Command
        desc "List gems cached in Geminabox"

        option :config, type: :string, desc: "Path to config file"

        def call(**options)
          config = Configuration.load(options[:config])

          gem_files = Dir.glob(File.join(config.gems_path, "gems", "*.gem"))

          if gem_files.empty?
            puts "No gems cached in Geminabox"
            puts "  Gems directory: #{config.gems_path}"
            return
          end

          puts "Cached gems:"
          gem_files.sort.each do |gem_file|
            gem_name = File.basename(gem_file, ".gem")
            puts "  #{gem_name}"
          end
        end
      end
    end

    register "list", Commands::List
  end
end
