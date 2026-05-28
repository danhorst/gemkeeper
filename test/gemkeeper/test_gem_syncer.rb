# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestGemSyncer < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def gem_def(attrs)
    Gemkeeper::Configuration::GemDefinition.new(attrs)
  end

  def manifest_with(entries)
    path = File.join(@tmpdir, "manifest.yml")
    File.write(path, { "gems" => entries }.to_yaml)
    Gemkeeper::ManifestReader.load(path)
  end

  def missing_manifest
    Gemkeeper::ManifestReader.load(File.join(@tmpdir, "absent.yml"))
  end

  def syncer(manifest)
    Gemkeeper::GemSyncer.new(nil, nil, manifest:)
  end

  def resolve(manifest, attrs)
    syncer(manifest).send(:resolve_repo, gem_def(attrs))
  end

  def test_resolves_repo_from_manifest_by_name
    manifest = manifest_with([{ "name" => "my-gem", "repo" => "git@github.com:co/my-gem.git" }])

    assert_equal "git@github.com:co/my-gem.git", resolve(manifest, name: "my-gem", version: "latest")
  end

  def test_explicit_repo_wins_over_manifest
    manifest = manifest_with([{ "name" => "my-gem", "repo" => "git@github.com:co/new.git" }])

    repo = resolve(manifest, name: "my-gem", repo: "git@github.com:co/old.git", version: "latest")

    assert_equal "git@github.com:co/old.git", repo
  end

  def test_warns_when_explicit_repo_diverges_from_manifest
    manifest = manifest_with([{ "name" => "my-gem", "repo" => "git@github.com:co/new.git" }])

    assert_output(nil, /differs from manifest/) do
      resolve(manifest, name: "my-gem", repo: "git@github.com:co/old.git", version: "latest")
    end
  end

  def test_no_warning_when_explicit_repo_matches_manifest
    manifest = manifest_with([{ "name" => "my-gem", "repo" => "git@github.com:co/my-gem.git" }])

    assert_silent do
      resolve(manifest, name: "my-gem", repo: "git@github.com:co/my-gem.git", version: "latest")
    end
  end

  def test_raises_when_manifest_file_missing
    error = assert_raises(Gemkeeper::InvalidConfigError) do
      resolve(missing_manifest, name: "my-gem", version: "latest")
    end

    assert_match(/No manifest found/, error.message)
  end

  def test_raises_when_gem_absent_from_manifest
    manifest = manifest_with([{ "name" => "other-gem", "repo" => "git@github.com:co/other.git" }])

    error = assert_raises(Gemkeeper::InvalidConfigError) do
      resolve(manifest, name: "my-gem", version: "latest")
    end

    assert_match(/No repo configured for "my-gem"/, error.message)
  end
end
