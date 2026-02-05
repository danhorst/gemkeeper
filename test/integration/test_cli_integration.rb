# frozen_string_literal: true

require "integration_helper"

class TestCLIIntegration < Minitest::Test
  include IntegrationHelper

  def test_version_command
    result = run_gemkeeper("version")

    assert_match(/gemkeeper \d+\.\d+\.\d+/, result[:stdout])
  end

  def test_version_alias_v
    result = run_gemkeeper("-v")

    assert_match(/gemkeeper \d+\.\d+\.\d+/, result[:stdout])
  end

  def test_version_alias_version_flag
    result = run_gemkeeper("--version")

    assert_match(/gemkeeper \d+\.\d+\.\d+/, result[:stdout])
  end

  def test_list_with_no_gems
    with_config("port" => 9999, "gems_path" => "./cache/gems") do |_temp_dir, config_path|
      result = run_gemkeeper("list", "--config", config_path)

      assert_match(/No gems cached/, result[:stdout])
    end
  end

  def test_list_shows_cached_gems
    with_config("port" => 9999) do |temp_dir, config_path|
      gems_dir = File.join(temp_dir, "cache", "gems", "gems")
      FileUtils.mkdir_p(gems_dir)

      # Create fake gem files
      FileUtils.touch(File.join(gems_dir, "my-gem-1.0.0.gem"))
      FileUtils.touch(File.join(gems_dir, "other-gem-2.3.1.gem"))

      # Update config to use this gems_path
      config = { "port" => 9999, "gems_path" => File.join(temp_dir, "cache", "gems") }
      File.write(config_path, config.to_yaml)

      result = run_gemkeeper("list", "--config", config_path)

      assert_match(/Cached gems:/, result[:stdout])
      assert_match(/my-gem-1\.0\.0/, result[:stdout])
      assert_match(/other-gem-2\.3\.1/, result[:stdout])
    end
  end

  def test_server_status_when_not_running
    with_config("port" => 19_999) do |_temp_dir, config_path|
      result = run_gemkeeper("server", "status", "--config", config_path)

      assert_match(/not running/, result[:stdout])
    end
  end

  def test_sync_with_no_gems_configured
    with_config("port" => 9999) do |_temp_dir, config_path|
      result = run_gemkeeper("sync", "--config", config_path, allow_failure: true)

      assert_match(/No gems configured/, result[:stderr])
      refute result[:status].success?
    end
  end

  def test_sync_specific_gem_not_found
    config = {
      "port" => 9999,
      "gems" => [
        { "repo" => "git@github.com:example/existing-gem.git", "version" => "latest" }
      ]
    }

    with_config(config) do |_temp_dir, config_path|
      result = run_gemkeeper("sync", "nonexistent-gem", "--config", config_path, allow_failure: true)

      assert_match(/No matching gem found/, result[:stderr])
      refute result[:status].success?
    end
  end

  def test_server_stop_when_not_running
    with_config("port" => 19_999) do |_temp_dir, config_path|
      result = run_gemkeeper("server", "stop", "--config", config_path, allow_failure: true)

      assert_match(/not running/, result[:stderr])
      refute result[:status].success?
    end
  end

  def test_server_start_help_shows_foreground_option
    result = run_gemkeeper("server", "start", "--help")

    assert_match(/foreground/, result[:stdout])
    assert_match(/-f/, result[:stdout])
    assert_match(/don't daemonize/, result[:stdout])
  end
end
