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

  def test_server_stop_when_not_running_exits_zero
    with_config("port" => 19_999) do |_temp_dir, config_path|
      result = run_gemkeeper("server", "stop", "--config", config_path)

      assert result[:status].success?
      assert_match(/not running/, result[:stdout])
    end
  end

  def test_explicit_config_path_not_found_gives_clear_error
    result = run_gemkeeper("sync", "--config", "/nonexistent/gemkeeper.yml", allow_failure: true)

    refute result[:status].success?
    assert_match(/config file not found/i, result[:stderr])
  end

  def test_server_start_help_shows_foreground_option
    result = run_gemkeeper("server", "start", "--help")

    assert_match(/foreground/, result[:stdout])
    assert_match(/-f/, result[:stdout])
    assert_match(/don't daemonize/, result[:stdout])
  end

  def test_sync_skips_already_cached_gem
    with_config("port" => 9999) do |temp_dir, config_path|
      gems_dir = File.join(temp_dir, "cache", "gems", "gems")
      FileUtils.mkdir_p(gems_dir)
      FileUtils.touch(File.join(gems_dir, "my-gem-1.2.3.gem"))

      config = {
        "port" => 9999,
        "gems_path" => File.join(temp_dir, "cache", "gems"),
        "gems" => [{ "repo" => "git@github.com:example/my-gem.git", "version" => "1.2.3" }]
      }
      File.write(config_path, config.to_yaml)

      result = run_gemkeeper("sync", "--config", config_path)

      assert_match(/already cached/, result[:stdout])
      assert_match(/Sync complete:/, result[:stdout])
      assert_match(/1 skipped/, result[:stdout])
    end
  end

  def test_help_exits_zero
    result = run_gemkeeper("--help")

    assert result[:status].success?
  end

  def test_server_help_exits_zero
    result = run_gemkeeper("server", "--help")

    assert result[:status].success?
  end

  def test_sync_from_lockfile_no_lockfile_exits_nonzero
    config = {
      "port" => 9999,
      "gems" => [{ "repo" => "git@github.com:example/my-gem.git", "version" => "from_lockfile" }]
    }

    # Run from a temp dir guaranteed to have no Gemfile.lock above it
    Dir.mktmpdir do |tmpdir|
      config_path = File.join(tmpdir, "gemkeeper.yml")
      File.write(config_path, config.to_yaml)

      stdout, stderr, status = Open3.capture3(
        ENV.to_h,
        "bundle", "exec", "ruby",
        IntegrationHelper::GEMKEEPER_BIN,
        "sync", "--config", config_path,
        chdir: tmpdir
      )

      refute status.success?, "Expected non-zero exit"
      assert_match(/no Gemfile.lock found|from_lockfile/i, "#{stdout}\n#{stderr}")
    end
  end
end
