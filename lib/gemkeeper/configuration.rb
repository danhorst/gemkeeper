# frozen_string_literal: true

require "yaml"
require "fileutils"

module Gemkeeper
  class Configuration
    DEFAULT_PORT = 9292
    DEFAULT_CONFIG_FILENAME = "gemkeeper.yml"

    # Config file lookup paths in order of priority
    CONFIG_PATHS = [
      -> { File.join(Dir.pwd, DEFAULT_CONFIG_FILENAME) },              # ./gemkeeper.yml
      -> { File.expand_path("~/.config/gemkeeper/config.yml") },       # XDG config
      -> { File.expand_path("~/.gemkeeper.yml") },                     # Home directory
      -> { "/usr/local/etc/gemkeeper.yml" },                           # Homebrew (Intel)
      -> { "/opt/homebrew/etc/gemkeeper.yml" }                         # Homebrew (Apple Silicon)
    ].freeze

    attr_reader :port, :repos_path, :gems_path, :pid_file, :gems

    def self.load(config_path = nil)
      new(config_path)
    end

    def self.config_search_paths
      CONFIG_PATHS.map { |p| p.is_a?(Proc) ? p.call : p }
    end

    def initialize(config_path = nil)
      @config_path = config_path || find_config_file
      @config = load_config
      apply_config
    end

    def geminabox_url
      "http://localhost:#{port}"
    end

    def config_ru_path
      File.join(cache_dir, "config.ru")
    end

    def cache_dir
      @cache_dir ||= begin
        dir = File.expand_path("./cache")
        FileUtils.mkdir_p(dir)
        dir
      end
    end

    private

    def find_config_file
      self.class.config_search_paths.find { |path| File.exist?(path) }
    end

    def load_config
      return {} unless @config_path && File.exist?(@config_path)

      begin
        YAML.safe_load_file(@config_path, permitted_classes: [], symbolize_names: true) || {}
      rescue Psych::SyntaxError => e
        raise InvalidConfigError, "Invalid YAML in #{@config_path}: #{e.message}"
      end
    end

    def apply_config
      @port = @config.fetch(:port, DEFAULT_PORT)
      @repos_path = File.expand_path(@config.fetch(:repos_path, "./cache/repos"))
      @gems_path = File.expand_path(@config.fetch(:gems_path, "./cache/gems"))
      @pid_file = File.expand_path(@config.fetch(:pid_file, "./cache/gemkeeper.pid"))
      @gems = (@config[:gems] || []).map { |g| GemDefinition.new(g) }

      FileUtils.mkdir_p(@repos_path)
      FileUtils.mkdir_p(@gems_path)
    end

    class GemDefinition
      attr_reader :repo, :version, :name

      def initialize(config)
        @repo = config[:repo] or raise InvalidConfigError, "Gem definition missing 'repo'"
        @version = config[:version] || "latest"
        @name = config[:name] || extract_name_from_repo
      end

      def latest?
        @version == "latest"
      end

      private

      def extract_name_from_repo
        File.basename(@repo, ".git").sub(/^ruby-/, "")
      end
    end
  end
end
