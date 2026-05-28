# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      class Sync < Dry::CLI::Command
        desc "Sync gems from configured repositories"

        argument :gem_name, type: :string, required: false, desc: "Specific gem to sync"
        option :config, type: :string, desc: "Path to config file"

        def call(gem_name: nil, **options)
          config = Configuration.load(options[:config])
          gems_to_sync = select_gems(config, gem_name)
          syncer = GemSyncer.new(config, GemUploader.new(config.geminabox_url))
          counts, failures = run_sync(gems_to_sync, syncer)
          report_results(counts, failures, gems_to_sync.size)
        end

        private

        def select_gems(config, gem_name)
          all_gems = config.gems
          if all_gems.empty?
            warn "No gems configured. Add gems to your gemkeeper.yml file."
            exit 1
          end

          gems = gem_name ? all_gems.select { |gem| gem.name == gem_name } : all_gems

          if gems.empty?
            warn "No matching gem found: #{gem_name}"
            exit 1
          end

          gems
        end

        def run_sync(gems_to_sync, syncer)
          counts = { synced: 0, skipped: 0 }
          failures = []
          gems_to_sync.each do |gem_def|
            counts[syncer.sync(gem_def)] += 1
          rescue ServerNotReachableError => error
            warn "Error: #{error.message}"
            exit 1
          rescue Error => error
            failures << { name: gem_def.name, message: error.message }
          end
          [counts, failures]
        end

        def report_results(counts, failures, total)
          synced  = counts[:synced]
          skipped = counts[:skipped]
          failure_count = failures.size
          parts = []
          parts << Output.colorize("#{synced} synced", :green) if synced.positive?
          parts << Output.colorize("#{skipped} skipped", :yellow) if skipped.positive?
          parts << Output.colorize("#{failure_count} failed", :red) if failures.any?
          puts "\nSync complete: #{parts.join(", ")} (#{total} total)"

          return if failures.empty?

          warn "\nSync completed with #{failure_count} failure(s):"
          failures.each { |f| warn "  #{f[:name]}: #{f[:message]}" }
          exit 1
        end
      end
    end

    register "sync", Commands::Sync
  end
end
