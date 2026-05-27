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

    # Candidate paths for the global service config, in priority order
    GLOBAL_CONFIG_PATHS = [
      -> { "/opt/homebrew/etc/gemkeeper.yml" },
      -> { "/usr/local/etc/gemkeeper.yml" },
      -> { File.expand_path("~/.config/gemkeeper/config.yml") }
    ].freeze

    def self.global_config_paths
      override = ENV.fetch("GEMKEEPER_GLOBAL_CONFIG", nil)
      return [override] if override

      GLOBAL_CONFIG_PATHS.map(&:call)
    end

    def self.resolve_global_path
      global_config_paths.find { |path| File.directory?(File.dirname(path)) }
    end

    def self.global_data_dir(config_path)
      config_dir = File.dirname(File.expand_path(config_path))
      if config_dir.end_with?("/etc")
        File.join(File.dirname(config_dir), "var", "gemkeeper")
      else
        config_dir
      end
    end

    attr_reader :port, :repos_path, :gems_path, :pid_file, :gems

    def self.load(config_path = nil)
      new(config_path)
    end

    def self.config_search_paths
      CONFIG_PATHS.map(&:call)
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

    def validate_port!
      return if @port.is_a?(Integer) && (1..65_535).cover?(@port)

      raise InvalidConfigError,
            "port must be an integer between 1 and 65535, got #{@port.inspect}"
    end

    def find_config_file
      self.class.config_search_paths.find { |path| File.exist?(path) }
    end

    def load_config
      return {} unless @config_path && File.exist?(@config_path)

      begin
        YAML.safe_load_file(@config_path, permitted_classes: [], symbolize_names: true) || {}
      rescue Psych::SyntaxError => yaml_error
        raise InvalidConfigError, "Invalid YAML in #{@config_path}: #{yaml_error.message}"
      end
    end

    def apply_config
      @port = @config.fetch(:port, DEFAULT_PORT)
      validate_port!
      @repos_path = File.expand_path(@config.fetch(:repos_path, "./cache/repos"))
      @gems_path = File.expand_path(@config.fetch(:gems_path, "./cache/gems"))
      @pid_file = File.expand_path(@config.fetch(:pid_file, "./cache/gemkeeper.pid"))
      @gems = (@config[:gems] || []).map { |gem_config| GemDefinition.new(gem_config) }

      FileUtils.mkdir_p(@repos_path)
      FileUtils.mkdir_p(@gems_path)
    end

    class GemDefinition
      VALID_VERSION_PATTERN = /\A[a-zA-Z0-9._-]+\z/
      RESERVED_VERSIONS = %w[latest from_lockfile].freeze

      attr_reader :repo, :version, :name

      def initialize(config)
        @repo = config[:repo] or raise InvalidConfigError, "Gem definition missing 'repo'"
        @version = config[:version] || "latest"
        @name = config[:name] || extract_name_from_repo
        validate_version!
      end

      def latest?
        @version == "latest"
      end

      def from_lockfile?
        @version == "from_lockfile"
      end

      private

      def validate_version!
        return if RESERVED_VERSIONS.include?(@version)
        return if @version.match?(VALID_VERSION_PATTERN)

        raise InvalidConfigError,
              "Invalid version #{@version.inspect} for gem #{@name.inspect} — " \
              "must be \"latest\", \"from_lockfile\", or a tag string matching [a-zA-Z0-9._-]"
      end

      def extract_name_from_repo
        File.basename(@repo, ".git").sub(/^ruby-/, "")
      end
    end
  end
end
