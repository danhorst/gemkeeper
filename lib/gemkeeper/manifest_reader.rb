# frozen_string_literal: true

require "yaml"

module Gemkeeper
  class ManifestReader
    DEFAULT_PATH = File.expand_path("~/.config/gemkeeper/manifest.yml")

    attr_reader :gems, :source_url

    def self.load(path = DEFAULT_PATH)
      new(path)
    end

    def initialize(path)
      @path = path
      raise ManifestNotFoundError, manifest_not_found_message unless File.exist?(@path)

      parse_manifest
    end

    def gem_names
      @gems.map { |gem_entry| gem_entry[:name] }
    end

    def find_by_name(name)
      @gems.find { |gem_entry| gem_entry[:name] == name }
    end

    private

    def parse_manifest
      data = YAML.safe_load_file(@path, permitted_classes: [], symbolize_names: true) || {}
      @source_url = data[:source_url]&.to_s
      @gems = (data[:gems] || []).map do |entry|
        { name: entry[:name].to_s, repo: entry[:repo].to_s }
      end
    end

    def manifest_not_found_message
      "Manifest not found at #{@path}. " \
        "Install your org's gem manifest, then re-run setup."
    end
  end
end
