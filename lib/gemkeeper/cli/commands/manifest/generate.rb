# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      module Manifest
        class Generate < Dry::CLI::Command
          desc "Build or update the gem manifest from a Gemfile.lock"

          argument :lockfile_path, type: :string, required: true,
                                   desc: "Path to the project's Gemfile.lock"
          option :manifest, type: :string,
                            desc: "Path to write manifest (default: ~/.config/gemkeeper/manifest.yml)"

          def call(lockfile_path:, **options)
            path = manifest_path(options)
            manifest = ManifestReader.load(path)
            result = ManifestBuilder.build(lockfile_path:, manifest:)

            if result.empty?
              puts "No internal gem sources found in #{lockfile_path}"
              return
            end

            if result.any_changes?
              manifest.save(path)
              puts "Wrote #{path}"
            end

            print_summary(result, result.any_changes? ? nil : "Manifest up to date, no changes")
          rescue UnresolvableGemError, ManifestConflictError => error
            warn "Error: #{error.message}"
            exit 1
          end

          private

          def manifest_path(options)
            options[:manifest] || ManifestReader::DEFAULT_PATH
          end

          def print_summary(result, no_change_message)
            if no_change_message
              puts no_change_message
              return
            end

            parts = []
            parts << "#{result.added_count} added" if result.added_count.positive?
            parts << "#{result.skipped_count} skipped" if result.skipped_count.positive?
            parts << "#{result.already_mapped_count} already mapped" if result.already_mapped_count.positive?
            puts parts.join(", ") if parts.any?
          end
        end
      end
    end

    register "manifest generate", Commands::Manifest::Generate
  end
end
