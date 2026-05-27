# frozen_string_literal: true

require "integration_helper"
require "yaml"

class TestSetupIntegration < Minitest::Test
  include IntegrationHelper

  FIXTURE_LOCKFILE = File.join(IntegrationHelper::FIXTURES_PATH, "sample.lock")
  FIXTURE_MANIFEST = File.join(IntegrationHelper::FIXTURES_PATH, "sample_manifest.yml")

  def test_setup_generates_gemkeeper_yml
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", FIXTURE_MANIFEST,
        "--config", output
      )

      assert result[:status].success?, "Expected success:\n#{result[:stderr]}"
      assert File.exist?(output), "gemkeeper.yml was not created"

      config = YAML.safe_load_file(output)
      gem_names = config["gems"].map { |g| File.basename(g["repo"]) }

      assert_includes gem_names, "internal-gem-one"
      assert_includes gem_names, "internal-gem-two"
    end
  end

  def test_setup_uses_from_lockfile_version
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")

      run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", FIXTURE_MANIFEST, "--config", output)

      config = YAML.safe_load_file(output)
      config["gems"].each do |gem_entry|
        assert_equal "from_lockfile", gem_entry["version"], "Expected from_lockfile version"
      end
    end
  end

  def test_setup_excludes_gems_not_in_lockfile
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")

      run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", FIXTURE_MANIFEST, "--config", output)

      config = YAML.safe_load_file(output)
      gem_names = config["gems"].map { |g| File.basename(g["repo"]) }

      # other-internal-gem is in manifest but not in the lockfile
      refute_includes gem_names, "other-internal-gem"
    end
  end

  def test_setup_merges_into_existing_config
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      existing = { "port" => 8080, "repos_path" => "./my_repos", "gems" => [] }
      File.write(output, existing.to_yaml)

      run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", FIXTURE_MANIFEST, "--config", output)

      config = YAML.safe_load_file(output)
      assert_equal 8080, config["port"], "Existing port should be preserved"
      assert_equal "./my_repos", config["repos_path"], "Existing repos_path should be preserved"
      refute_empty config["gems"]
    end
  end

  def test_setup_force_overwrites_existing_config
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      File.write(output, { "port" => 8080 }.to_yaml)

      run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", FIXTURE_MANIFEST,
                    "--config", output, "--force")

      config = YAML.safe_load_file(output)
      assert_equal 9292, config["port"], "Force should reset to default port"
    end
  end

  def test_setup_prints_bundle_config_instruction
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")

      result = run_gemkeeper("setup", FIXTURE_LOCKFILE, "--manifest", FIXTURE_MANIFEST, "--config", output)

      assert_match(/bundle config set --local mirror/, result[:stdout])
      assert_match(/localhost:9292/, result[:stdout])
    end
  end

  def test_setup_exits_nonzero_when_manifest_missing
    Dir.mktmpdir do |tmpdir|
      output = File.join(tmpdir, "gemkeeper.yml")
      missing_manifest = File.join(tmpdir, "missing.yml")

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", missing_manifest,
        "--config", output,
        allow_failure: true
      )

      refute result[:status].success?
      assert_match(/manifest/i, result[:stderr])
    end
  end

  def test_setup_command_appears_in_help
    result = run_gemkeeper("setup", "--help")

    assert_match(/LOCKFILE_PATH/, result[:stdout])
    assert_match(/manifest/i, result[:stdout])
  end

  def test_global_writes_to_resolved_path
    Dir.mktmpdir do |tmpdir|
      global_path = File.join(tmpdir, "gemkeeper.yml")

      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", FIXTURE_MANIFEST,
        "--global",
        env: { "GEMKEEPER_GLOBAL_CONFIG" => global_path }
      )

      assert result[:status].success?, "Expected success:\n#{result[:stderr]}"
      assert File.exist?(global_path), "Global config was not created"

      config = YAML.safe_load_file(global_path)
      gem_names = config["gems"].map { |g| File.basename(g["repo"]) }
      assert_includes gem_names, "internal-gem-one"
      assert_includes gem_names, "internal-gem-two"
    end
  end

  def test_global_uses_absolute_paths
    Dir.mktmpdir do |tmpdir|
      global_path = File.join(tmpdir, "gemkeeper.yml")

      run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", FIXTURE_MANIFEST,
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
      existing = { "port" => 8080, "repos_path" => "/custom/repos", "gems" => [] }
      File.write(global_path, existing.to_yaml)

      run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", FIXTURE_MANIFEST,
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
      result = run_gemkeeper(
        "setup", FIXTURE_LOCKFILE,
        "--manifest", FIXTURE_MANIFEST,
        "--global",
        "--config", File.join(tmpdir, "gemkeeper.yml"),
        allow_failure: true
      )

      refute result[:status].success?
      assert_match(/mutually exclusive/, result[:stderr])
    end
  end

  def test_global_fails_when_no_writable_path
    result = run_gemkeeper(
      "setup", FIXTURE_LOCKFILE,
      "--manifest", FIXTURE_MANIFEST,
      "--global",
      allow_failure: true,
      env: { "GEMKEEPER_GLOBAL_CONFIG" => "/nonexistent/parent/gemkeeper.yml" }
    )

    refute result[:status].success?
    assert_match(/no writable global config path/i, result[:stderr])
  end
end
