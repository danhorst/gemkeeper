# frozen_string_literal: true

module Gemkeeper
  module CLI
    module Commands
      module Manifest
        class Validate < Dry::CLI::Command
          desc "Validate a gem manifest file"

          argument :path, type: :string, required: false,
                          desc: "Path to manifest (default: ~/.config/gemkeeper/manifest.yml)"
          option :resolve, type: :boolean, default: false,
                           desc: "Also verify each repo is reachable via git ls-remote"

          def call(path: nil, **options)
            manifest_path = path || ManifestReader::DEFAULT_PATH
            validator = ManifestValidator.new(manifest_path)

            puts "Checking #{manifest_path}..." if options[:resolve]
            errors = validator.validate(resolve: options[:resolve], output: $stdout)

            if errors.empty?
              entry_count = entry_count(manifest_path)
              puts "#{manifest_path}: valid (#{entry_count} #{"entry".then { |w| entry_count == 1 ? w : "#{w}s" }})"
            else
              warn "#{manifest_path}: #{errors.size} #{"error".then { |w| errors.size == 1 ? w : "#{w}s" }}"
              errors.each { |e| warn "  #{e}" }
              exit 1
            end
          end

          private

          def entry_count(path)
            return 0 unless File.exist?(path)

            data = YAML.safe_load_file(path, permitted_classes: [], symbolize_names: false) || {}
            (data["gems"] || []).size
          end
        end
      end
    end

    register "manifest validate", Commands::Manifest::Validate
  end
end
