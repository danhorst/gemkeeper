# frozen_string_literal: true

require "integration_helper"
require "yaml"

class TestManifestIntegration < Minitest::Test
  include IntegrationHelper

  FIXTURE_LOCKFILE = File.join(IntegrationHelper::FIXTURES_PATH, "sample.lock")
  FIXTURE_MANIFEST = File.join(IntegrationHelper::FIXTURES_PATH, "sample_manifest.yml")

  def test_generate_creates_manifest_from_lockfile
    Dir.mktmpdir do |tmpdir|
      manifest_path = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper("manifest", "generate", FIXTURE_LOCKFILE, "--manifest", manifest_path)

      assert result[:status].success?, result[:stderr]
      assert File.exist?(manifest_path)
      manifest = YAML.safe_load_file(manifest_path)
      names = manifest["gems"].map { |g| g["name"] }
      assert_includes names, "git-sourced-gem"
      assert_includes names, "internal-gem-one"
    end
  end

  def test_generate_merges_with_existing_manifest
    Dir.mktmpdir do |tmpdir|
      manifest_path = File.join(tmpdir, "manifest.yml")
      FileUtils.cp(FIXTURE_MANIFEST, manifest_path)

      run_gemkeeper("manifest", "generate", FIXTURE_LOCKFILE, "--manifest", manifest_path)

      manifest = YAML.safe_load_file(manifest_path)
      names = manifest["gems"].map { |g| g["name"] }
      assert_includes names, "other-internal-gem"
      assert_includes names, "git-sourced-gem"
    end
  end

  def test_generate_force_overwrites_existing_manifest
    Dir.mktmpdir do |tmpdir|
      manifest_path = File.join(tmpdir, "manifest.yml")
      FileUtils.cp(FIXTURE_MANIFEST, manifest_path)

      run_gemkeeper("manifest", "generate", FIXTURE_LOCKFILE, "--manifest", manifest_path, "--force")

      manifest = YAML.safe_load_file(manifest_path)
      names = manifest["gems"].map { |g| g["name"] }
      refute_includes names, "other-internal-gem"
    end
  end

  def test_generate_reports_no_internal_sources
    Dir.mktmpdir do |tmpdir|
      lockfile = File.join(tmpdir, "Gemfile.lock")
      File.write(lockfile, <<~LOCK)
        GEM
          remote: https://rubygems.org/
          specs:
            rack (2.2.7)
        PLATFORMS
          ruby
        DEPENDENCIES
          rack
        BUNDLED WITH
           2.4.10
      LOCK
      manifest_path = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper("manifest", "generate", lockfile, "--manifest", manifest_path)

      assert result[:status].success?
      assert_match(/No internal gem sources/, result[:stdout])
    end
  end

  def test_generate_prints_added_count
    Dir.mktmpdir do |tmpdir|
      manifest_path = File.join(tmpdir, "manifest.yml")

      result = run_gemkeeper("manifest", "generate", FIXTURE_LOCKFILE, "--manifest", manifest_path)

      assert_match(/added/, result[:stdout])
    end
  end

  def test_generate_reports_up_to_date_when_no_changes
    Dir.mktmpdir do |tmpdir|
      manifest_path = File.join(tmpdir, "manifest.yml")
      run_gemkeeper("manifest", "generate", FIXTURE_LOCKFILE, "--manifest", manifest_path)

      result = run_gemkeeper("manifest", "generate", FIXTURE_LOCKFILE, "--manifest", manifest_path)

      assert result[:status].success?
      assert_match(/up to date/, result[:stdout])
    end
  end

  def test_validate_succeeds_on_valid_manifest
    result = run_gemkeeper("manifest", "validate", FIXTURE_MANIFEST)

    assert result[:status].success?
    assert_match(/valid/, result[:stdout])
  end

  def test_validate_reports_entry_count
    result = run_gemkeeper("manifest", "validate", FIXTURE_MANIFEST)

    assert_match(/3 entries/, result[:stdout])
  end

  def test_validate_fails_on_missing_file
    result = run_gemkeeper("manifest", "validate", "/nonexistent/manifest.yml", allow_failure: true)

    refute result[:status].success?
    assert_match(/error/, result[:stderr])
  end

  def test_validate_fails_on_invalid_manifest
    Dir.mktmpdir do |tmpdir|
      path = File.join(tmpdir, "manifest.yml")
      File.write(path, <<~YAML)
        gems:
          - name: my-gem
      YAML

      result = run_gemkeeper("manifest", "validate", path, allow_failure: true)

      refute result[:status].success?
      assert_match(/missing repo/, result[:stderr])
    end
  end

  def test_validate_uses_default_manifest_path_when_no_arg
    result = run_gemkeeper("manifest", "validate", "--help")

    assert_match(/manifest\.yml/, result[:stdout])
  end

  def test_generate_command_appears_in_help
    result = run_gemkeeper("manifest", "generate", "--help")

    assert_match(/LOCKFILE_PATH/, result[:stdout])
    assert_match(/force/, result[:stdout])
    assert_match(/--manifest/, result[:stdout])
  end

  def test_validate_command_appears_in_help
    result = run_gemkeeper("manifest", "validate", "--help")

    assert_match(/resolve/, result[:stdout])
  end
end
