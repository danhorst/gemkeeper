# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "fileutils"

class TestConfiguration < Minitest::Test
  def setup
    @original_dir = Dir.pwd
    @temp_dir = Dir.mktmpdir
    Dir.chdir(@temp_dir)
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(@temp_dir)
  end

  def test_default_values
    config = Gemkeeper::Configuration.load

    assert_equal 9292, config.port
    assert_equal "http://localhost:9292", config.geminabox_url
    assert config.repos_path.end_with?("cache/repos")
    assert config.gems_path.end_with?("cache/gems")
    assert_empty config.gems
  end

  def test_loads_local_config
    File.write("gemkeeper.yml", <<~YAML)
      port: 8080
      repos_path: ./my_repos
      gems_path: ./my_gems
    YAML

    config = Gemkeeper::Configuration.load

    assert_equal 8080, config.port
    assert config.repos_path.end_with?("my_repos")
    assert config.gems_path.end_with?("my_gems")
  end

  def test_loads_gems_from_config
    File.write("gemkeeper.yml", <<~YAML)
      gems:
        - repo: git@github.com:company/my-gem.git
          version: v1.2.3
        - repo: git@github.com:company/other-gem.git
          version: latest
    YAML

    config = Gemkeeper::Configuration.load

    assert_equal 2, config.gems.size

    gem1 = config.gems[0]
    assert_equal "git@github.com:company/my-gem.git", gem1.repo
    assert_equal "v1.2.3", gem1.version
    assert_equal "my-gem", gem1.name
    refute gem1.latest?

    gem2 = config.gems[1]
    assert_equal "git@github.com:company/other-gem.git", gem2.repo
    assert_equal "latest", gem2.version
    assert_equal "other-gem", gem2.name
    assert gem2.latest?
  end

  def test_explicit_config_path
    config_path = File.join(@temp_dir, "custom.yml")
    File.write(config_path, <<~YAML)
      port: 3000
    YAML

    config = Gemkeeper::Configuration.load(config_path)

    assert_equal 3000, config.port
  end

  def test_invalid_yaml_raises_error
    File.write("gemkeeper.yml", "invalid: yaml: content: [")

    assert_raises(Gemkeeper::InvalidConfigError) do
      Gemkeeper::Configuration.load
    end
  end

  def test_gem_definition_requires_repo
    File.write("gemkeeper.yml", <<~YAML)
      gems:
        - version: latest
    YAML

    assert_raises(Gemkeeper::InvalidConfigError) do
      Gemkeeper::Configuration.load
    end
  end

  def test_extracts_gem_name_from_repo_url
    File.write("gemkeeper.yml", <<~YAML)
      gems:
        - repo: git@github.com:company/ruby-awesome.git
    YAML

    config = Gemkeeper::Configuration.load

    assert_equal "awesome", config.gems[0].name
  end

  def test_custom_gem_name
    File.write("gemkeeper.yml", <<~YAML)
      gems:
        - repo: git@github.com:company/my-gem.git
          name: custom_name
    YAML

    config = Gemkeeper::Configuration.load

    assert_equal "custom_name", config.gems[0].name
  end
end
