# frozen_string_literal: true

require "integration_helper"
require "yaml"

class TestSetupIntegration < Minitest::Test
  include IntegrationHelper

  FIXTURE_LOCKFILE = File.join(IntegrationHelper::FIXTURES_PATH, "sample.lock")
  FIXTURE_MANIFEST = File.join(IntegrationHelper::FIXTURES_PATH, "sample_manifest.yml")

  def test_setup_generates_gemkeeper_yml_from_lockfile
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--config", output
      )

      assert result[:status].success?, "Expected success:\n#{result[:stderr]}"
      assert File.exist?(output), "gemkeeper.yml was not created"

      config = YAML.safe_load_file(output)
      gem_names = config["gems"].map { |g| g["name"] }

      assert_includes gem_names, "internal-gem-one"
      assert_includes gem_names, "internal-gem-two"
      assert_includes gem_names, "git-sourced-gem"
    end
  end

  def test_setup_creates_manifest_from_lockfile
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest_path = File.join(tmpdir, "manifest.yml")

      run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", manifest_path, "--config", output)

      assert File.exist?(manifest_path), "manifest.yml was not created"
      manifest = YAML.safe_load_file(manifest_path)
      names = manifest["gems"].map { |g| g["name"] }
      assert_includes names, "git-sourced-gem"
      assert_includes names, "internal-gem-one"
    end
  end

  def test_setup_uses_from_lockfile_version
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", manifest, "--config", output)

      config = YAML.safe_load_file(output)
      config["gems"].each do |gem_entry|
        assert_equal "from_lockfile", gem_entry["version"], "Expected from_lockfile version"
      end
    end
  end

  def test_setup_merges_into_existing_config
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")
      existing = { "port" => 8080, "repos_path" => "./my_repos", "gems" => [] }
      File.write(output, existing.to_yaml)

      run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", manifest, "--config", output)

      config = YAML.safe_load_file(output)
      assert_equal 8080, config["port"], "Existing port should be preserved"
      assert_equal "./my_repos", config["repos_path"], "Existing repos_path should be preserved"
      refute_empty config["gems"]
    end
  end

  def test_setup_force_overwrites_existing_config
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")
      File.write(output, { "port" => 8080 }.to_yaml)

      run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", manifest, "--config", output, "--force")

      config = YAML.safe_load_file(output)
      assert_equal 9292, config["port"], "Force should reset to default port"
    end
  end

  def test_setup_prints_bundle_config_instruction
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", manifest, "--config", output)

      assert_match(/bundle config set --local mirror/, result[:stdout])
      assert_match(/localhost:9292/, result[:stdout])
    end
  end

  def test_setup_with_existing_manifest_reuses_mappings
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")
      FileUtils.cp(FIXTURE_MANIFEST, manifest)

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--config", output
      )

      assert result[:status].success?, "Expected success:\n#{result[:stderr]}"
      config = YAML.safe_load_file(output)
      gem_names = config["gems"].map { |g| g["name"] }
      assert_includes gem_names, "internal-gem-one"
    end
  end

  def test_setup_rejects_non_lockfile_source
    Dir.mktmpdir do |tmpdir|
      source_config = File.join(tmpdir, "gemkeeper.yml")
      File.write(source_config, { "gems" => [{ "name" => "my-gem", "version" => "latest" }] }.to_yaml)

      result = run_gemkeeper("setup", source_config,
                             "--config", File.join(tmpdir, "out.yml"), allow_failure: true)

      refute result[:status].success?, "Expected non-zero exit for a non-lockfile source"
      assert_match(/Gemfile\.lock/, result[:stderr])
      assert_match(/manifest generate/, result[:stderr])
    end
  end

  def test_setup_configures_bundler_mirrors
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")
      bundle_cfg = File.join(tmpdir, "bundle_cfg")

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--config", output,
        env: { "BUNDLE_APP_CONFIG" => bundle_cfg }
      )

      assert_match(%r{Configured:.*mirror\.https://rubygems\.pkg\.github\.com}, result[:stdout])
      assert_match(/localhost:9292/, result[:stdout])
    end
  end

  def test_setup_skip_bundler_config_omits_mirror_setup
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--config", output,
        "--skip-bundler-config"
      )

      assert result[:status].success?
      refute_match(/Configured:/, result[:stdout])
    end
  end

  def test_setup_global_uses_global_bundler_scope
    Dir.mktmpdir do |tmpdir|
      global_path = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")
      bundle_cfg = File.join(tmpdir, "bundle_cfg")

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--global",
        env: { "GEMKEEPER_GLOBAL_CONFIG" => global_path, "BUNDLE_USER_CONFIG" => bundle_cfg }
      )

      assert_match(/--global/, result[:stdout])
    end
  end

  def test_setup_command_appears_in_help
    result = run_gemkeeper("setup", "--help")

    assert_match(/SOURCE_PATH/, result[:stdout])
  end

  def test_global_writes_to_resolved_path
    Dir.mktmpdir do |tmpdir|
      global_path = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--global",
        env: { "GEMKEEPER_GLOBAL_CONFIG" => global_path }
      )

      assert result[:status].success?, "Expected success:\n#{result[:stderr]}"
      assert File.exist?(global_path), "Global config was not created"

      config = YAML.safe_load_file(global_path)
      gem_names = config["gems"].map { |g| g["name"] }
      assert_includes gem_names, "internal-gem-one"
    end
  end

  def test_global_uses_absolute_paths
    Dir.mktmpdir do |tmpdir|
      global_path = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--global",
        env: { "GEMKEEPER_GLOBAL_CONFIG" => global_path }
      )

      config = YAML.safe_load_file(global_path)
      assert config["repos_path"].start_with?("/"), "repos_path should be absolute"
      assert config["gems_path"].start_with?("/"), "gems_path should be absolute"
    end
  end

  def test_global_merges_with_existing_config
    Dir.mktmpdir do |tmpdir|
      global_path = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")
      existing = { "port" => 8080, "repos_path" => "/custom/repos", "gems" => [] }
      File.write(global_path, existing.to_yaml)

      run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--global",
        env: { "GEMKEEPER_GLOBAL_CONFIG" => global_path }
      )

      config = YAML.safe_load_file(global_path)
      assert_equal 8080, config["port"], "Existing port should be preserved"
      assert_equal "/custom/repos", config["repos_path"], "Existing repos_path should be preserved"
      refute_empty config["gems"]
    end
  end

  def test_global_and_config_are_mutually_exclusive
    Dir.mktmpdir do |tmpdir|
      manifest = File.join(tmpdir, "manifest.yml")
      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--global",
        "--config", File.join(tmpdir, "gemkeeper.yml"),
        allow_failure: true
      )

      refute result[:status].success?
      assert_match(/mutually exclusive/, result[:stderr])
    end
  end

  def test_global_fails_when_no_writable_path
    Dir.mktmpdir do |tmpdir|
      manifest = File.join(tmpdir, "manifest.yml")
      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", manifest,
        "--global",
        allow_failure: true,
        env: { "GEMKEEPER_GLOBAL_CONFIG" => "/nonexistent/parent/gemkeeper.yml" }
      )

      refute result[:status].success?
      assert_match(/no writable global config path/i, result[:stderr])
    end
  end

  def test_setup_with_no_args_finds_nearest_lockfile
    Dir.mktmpdir do |tmpdir|
      FileUtils.cp(FIXTURE_LOCKFILE, File.join(tmpdir, "Gemfile.lock"))
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper(
        "setup",
        "--manifest", manifest,
        "--config", output,
        "--skip-bundler-config",
        chdir: tmpdir
      )

      assert result[:status].success?, "Expected success:\n#{result[:stderr]}"
      assert File.exist?(output)
    end
  end

  def test_setup_with_directory_finds_lockfile_inside
    Dir.mktmpdir do |tmpdir|
      FileUtils.cp(FIXTURE_LOCKFILE, File.join(tmpdir, "Gemfile.lock"))
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper(
        "setup", tmpdir,
        "--manifest", manifest,
        "--config", output,
        "--skip-bundler-config"
      )

      assert result[:status].success?, "Expected success:\n#{result[:stderr]}"
      assert File.exist?(output)
    end
  end

  def test_setup_with_gemfile_path_uses_sibling_lockfile
    Dir.mktmpdir do |tmpdir|
      FileUtils.cp(FIXTURE_LOCKFILE, File.join(tmpdir, "Gemfile.lock"))
      File.write(File.join(tmpdir, "Gemfile"), "# stub")
      output = File.join(tmpdir, "gemkeeper.yml")
      manifest = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper(
        "setup", File.join(tmpdir, "Gemfile"),
        "--manifest", manifest,
        "--config", output,
        "--skip-bundler-config"
      )

      assert result[:status].success?, "Expected success:\n#{result[:stderr]}"
      assert File.exist?(output)
    end
  end

  def test_setup_with_missing_path_gives_clear_error
    result = run_gemkeeper(
      "setup", "/nonexistent/path/Gemfile.lock",
      allow_failure: true
    )

    refute result[:status].success?
    assert_match(/file not found/i, result[:stderr])
  end

  def test_setup_with_no_args_and_no_lockfile_gives_clear_error
    Dir.mktmpdir do |tmpdir|
      result = run_gemkeeper(
        "setup",
        allow_failure: true,
        chdir: tmpdir
      )

      refute result[:status].success?
      assert_match(/no Gemfile\.lock found/i, result[:stderr])
    end
  end
end
