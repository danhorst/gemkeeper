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

  def test_config_search_paths_returns_expected_locations
    paths = Gemkeeper::Configuration.config_search_paths

    assert_kind_of Array, paths
    assert paths.length >= 3
    assert(paths.any? { |p| p.end_with?("gemkeeper.yml") })
    assert(paths.any? { |p| p.include?(".config/gemkeeper") })
  end

  def test_resolve_global_path_uses_env_var_override
    Dir.mktmpdir do |tmpdir|
      global_path = File.join(tmpdir, "gemkeeper.yml")

      with_env("GEMKEEPER_GLOBAL_CONFIG" => global_path) do
        assert_equal global_path, Gemkeeper::Configuration.resolve_global_path
      end
    end
  end

  def test_resolve_global_path_returns_nil_when_no_parent_exists
    with_env("GEMKEEPER_GLOBAL_CONFIG" => "/nonexistent/parent/gemkeeper.yml") do
      assert_nil Gemkeeper::Configuration.resolve_global_path
    end
  end

  def test_global_data_dir_for_etc_based_path
    result = Gemkeeper::Configuration.global_data_dir("/opt/homebrew/etc/gemkeeper.yml")
    assert_equal "/opt/homebrew/var/gemkeeper", result
  end

  def test_global_data_dir_for_xdg_path
    result = Gemkeeper::Configuration.global_data_dir(File.expand_path("~/.config/gemkeeper/config.yml"))
    assert_equal File.expand_path("~/.config/gemkeeper"), result
  end

  def test_global_data_dir_for_arbitrary_dir
    result = Gemkeeper::Configuration.global_data_dir("/tmp/some/dir/gemkeeper.yml")
    assert_equal "/tmp/some/dir", result
  end

  private

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV.store(k, v) }
  end

  def test_from_lockfile_version_recognized
    File.write("gemkeeper.yml", <<~YAML)
      gems:
        - repo: git@github.com:company/my-gem.git
          version: from_lockfile
    YAML

    config = Gemkeeper::Configuration.load
    gem_def = config.gems[0]

    assert gem_def.from_lockfile?
    refute gem_def.latest?
  end

  def test_invalid_port_out_of_range_raises_error
    File.write("gemkeeper.yml", "port: 99999")

    assert_raises(Gemkeeper::InvalidConfigError) do
      Gemkeeper::Configuration.load
    end
  end

  def test_non_integer_port_raises_error
    File.write("gemkeeper.yml", "port: not_a_number")

    assert_raises(Gemkeeper::InvalidConfigError) do
      Gemkeeper::Configuration.load
    end
  end

  def test_invalid_version_raises_error
    File.write("gemkeeper.yml", <<~YAML)
      gems:
        - repo: git@github.com:company/my-gem.git
          version: "--upload-pack=evil"
    YAML

    assert_raises(Gemkeeper::InvalidConfigError) do
      Gemkeeper::Configuration.load
    end
  end

  def test_valid_tag_versions_accepted
    File.write("gemkeeper.yml", <<~YAML)
      gems:
        - repo: git@github.com:company/gem-a.git
          version: v1.2.3
        - repo: git@github.com:company/gem-b.git
          version: 2.0.0-rc1
        - repo: git@github.com:company/gem-c.git
          version: "1.0"
    YAML

    config = Gemkeeper::Configuration.load

    assert_equal 3, config.gems.size
    assert_equal "v1.2.3", config.gems[0].version
    assert_equal "2.0.0-rc1", config.gems[1].version
  end
end
