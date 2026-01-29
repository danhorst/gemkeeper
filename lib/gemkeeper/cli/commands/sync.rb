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

          if config.gems.empty?
            warn "No gems configured. Add gems to your gemkeeper.yml file."
            exit 1
          end

          gems_to_sync = if gem_name
                           config.gems.select { |g| g.name == gem_name }
                         else
                           config.gems
                         end

          if gems_to_sync.empty?
            warn "No matching gem found: #{gem_name}"
            exit 1
          end

          uploader = GemUploader.new(config.geminabox_url)

          gems_to_sync.each do |gem_def|
            sync_gem(gem_def, config, uploader)
          end
        rescue Error => e
          warn "Error: #{e.message}"
          exit 1
        end

        private

        def sync_gem(gem_def, config, uploader)
          puts "Syncing #{gem_def.name}..."

          # Clone or pull the repository
          local_path = File.join(config.repos_path, gem_def.name)
          repo = GitRepository.new(gem_def.repo, local_path)

          puts "  Fetching from #{gem_def.repo}..."
          repo.clone_or_pull

          # Checkout the specified version
          puts "  Checking out #{gem_def.version}..."
          repo.checkout_version(gem_def.version)

          # Build the gem
          puts "  Building gem..."
          builder = GemBuilder.new(local_path)
          gem_path = builder.build

          # Upload to Geminabox
          puts "  Uploading to Geminabox..."
          result = uploader.upload(gem_path)

          puts "  #{result[:message]}"

          # Clean up the built gem file
          FileUtils.rm_f(gem_path)

          puts "  Done!"
        rescue GitError => e
          warn "  Git error: #{e.message}"
          raise
        rescue BuildError => e
          warn "  Build error: #{e.message}"
          raise
        rescue UploadError => e
          warn "  Upload error: #{e.message}"
          raise
        end
      end
    end

    register "sync", Commands::Sync
  end
end
