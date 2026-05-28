# frozen_string_literal: true

require "yaml"
require "fileutils"

module Gemkeeper
  # Handles YAML read/write for the gem manifest file.
  module ManifestSerializer
    def self.load(path)
      return {} unless File.exist?(path)

      YAML.safe_load_file(path, permitted_classes: [], symbolize_names: true) || {}
    end

    def self.save(path, gems:, source_url:)
      FileUtils.mkdir_p(File.dirname(path))
      data = {}
      data["source_url"] = source_url if source_url
      data["gems"] = gems.map { |g| { "name" => g[:name], "repo" => g[:repo] } }
      File.write(path, data.to_yaml)
    end
  end
end
