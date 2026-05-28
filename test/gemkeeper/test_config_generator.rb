# frozen_string_literal: true

require "test_helper"
require "yaml"
require "fileutils"

class TestConfigGenerator < Minitest::Test
  FIXTURE_MANIFEST = File.expand_path("../fixtures/sample_manifest.yml", __dir__)
  FIXTURE_LOCKFILE = File.expand_path("../fixtures/sample.lock", __dir__)

  def setup
    @manifest = Gemkeeper::ManifestReader.load(FIXTURE_MANIFEST)
    @lockfile_versions = Gemkeeper::LockfileParser.parse(FIXTURE_LOCKFILE)
    @tmpdir = Dir.mktmpdir
    @output_path = File.join(@tmpdir, "gemkeeper.yml")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def generator
    Gemkeeper::ConfigGenerator.new(manifest: @manifest, lockfile_versions: @lockfile_versions)
  end

  def gem_names(config)
    config["gems"].map { |entry| entry["name"] }
  end

  def test_build_includes_gems_present_in_lockfile
    config = generator.build(@output_path, force: false)

    assert_includes gem_names(config), "internal-gem-one"
    assert_includes gem_names(config), "internal-gem-two"
  end

  def test_build_omits_repo_field
    config = generator.build(@output_path, force: false)

    config["gems"].each do |entry|
      refute entry.key?("repo"), "Generated entries should not carry a repo field"
    end
  end

  def test_build_excludes_gems_not_in_lockfile
    config = generator.build(@output_path, force: false)

    refute_includes gem_names(config), "other-internal-gem"
  end

  def test_build_sets_from_lockfile_version
    config = generator.build(@output_path, force: false)

    config["gems"].each do |entry|
      assert_equal "from_lockfile", entry["version"]
    end
  end

  def test_build_fresh_uses_relative_paths
    config = generator.build(@output_path, force: false)

    assert_equal "./cache/repos", config["repos_path"]
    assert_equal "./cache/gems", config["gems_path"]
  end

  def test_build_with_global_output_path_uses_absolute_paths
    config = generator.build(@output_path, force: false, global_output_path: @output_path)

    assert config["repos_path"].start_with?("/"), "repos_path should be absolute"
    assert config["gems_path"].start_with?("/"), "gems_path should be absolute"
  end

  def test_build_merges_with_existing_config
    existing = { "port" => 8080, "repos_path" => "/custom/repos", "gems" => [] }
    File.write(@output_path, existing.to_yaml)

    config = generator.build(@output_path, force: false)

    assert_equal 8080, config["port"]
    assert_equal "/custom/repos", config["repos_path"]
    refute_empty config["gems"]
  end

  def test_build_force_ignores_existing_config
    existing = { "port" => 8080, "gems" => [] }
    File.write(@output_path, existing.to_yaml)

    config = generator.build(@output_path, force: true)

    assert_equal Gemkeeper::Configuration::DEFAULT_PORT, config["port"]
    refute_empty config["gems"]
  end

  def test_merge_preserves_existing_gems_not_in_lockfile
    existing = {
      "gems" => [{ "repo" => "git@github.com:company/other-internal-gem.git", "version" => "v1.0.0" }]
    }
    File.write(@output_path, existing.to_yaml)

    config = generator.build(@output_path, force: false)

    repos = config["gems"].map { |entry| entry["repo"] }
    assert_includes repos, "git@github.com:company/other-internal-gem.git"
  end

  def test_build_includes_explicit_name_field
    config = generator.build(@output_path, force: false)

    config["gems"].each do |entry|
      assert entry.key?("name"), "Expected every gem entry to have an explicit 'name' field"
    end
  end

  def test_merge_updates_version_on_existing_matched_gem
    existing = {
      "gems" => [{ "repo" => "https://github.com/company/internal-gem-one", "version" => "v1.0.0" }]
    }
    File.write(@output_path, existing.to_yaml)

    config = generator.build(@output_path, force: false)

    gem_entry = config["gems"].find { |entry| entry["name"] == "internal-gem-one" }
    assert_equal "from_lockfile", gem_entry["version"]
  end

  def test_merge_resolves_repo_only_entry_when_url_basename_differs_from_manifest_name
    manifest_content = <<~YAML
      gems:
        - name: internal-gem-one
          repo: https://github.com/company/different-basename
        - name: internal-gem-two
          repo: https://github.com/company/internal-gem-two
    YAML
    manifest_path = File.join(@tmpdir, "manifest.yml")
    File.write(manifest_path, manifest_content)
    manifest = Gemkeeper::ManifestReader.load(manifest_path)
    gen = Gemkeeper::ConfigGenerator.new(manifest:, lockfile_versions: @lockfile_versions)

    existing = {
      "gems" => [{ "repo" => "https://github.com/company/different-basename", "version" => "v1.0.0" }]
    }
    File.write(@output_path, existing.to_yaml)

    config = gen.build(@output_path, force: false)

    matches = config["gems"].select { |e| e["name"] == "internal-gem-one" }
    assert_equal 1, matches.length, "Expected one entry for internal-gem-one, not a duplicate"
    assert_equal "from_lockfile", matches.first["version"]
    refute matches.first.key?("repo"), "Matched entry should be promoted to manifest-only (no repo)"
  end

  def test_merge_strips_repo_from_matched_entry
    existing = {
      "gems" => [{
        "name" => "internal-gem-one",
        "repo" => "git@github.com:company/old-repo-name.git",
        "version" => "v1.0.0"
      }]
    }
    File.write(@output_path, existing.to_yaml)

    config = generator.build(@output_path, force: false)

    gem_entry = config["gems"].find { |entry| entry["name"] == "internal-gem-one" }
    assert gem_entry, "Expected to find internal-gem-one in merged config"
    assert_equal "from_lockfile", gem_entry["version"]
    refute gem_entry.key?("repo"), "Matched entry should be promoted to manifest-only (no repo)"
  end
end
