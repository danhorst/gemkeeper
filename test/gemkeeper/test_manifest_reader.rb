# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestManifestReader < Minitest::Test
  FIXTURE_MANIFEST = File.expand_path("../fixtures/sample_manifest.yml", __dir__)

  def setup
    @temp_dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_loads_gems_from_manifest
    reader = Gemkeeper::ManifestReader.load(FIXTURE_MANIFEST)

    assert_equal 3, reader.gems.size
    assert_equal "internal-gem-one", reader.gems[0][:name]
    assert_equal "https://github.com/company/internal-gem-one", reader.gems[0][:repo]
  end

  def test_gem_names_returns_list_of_names
    reader = Gemkeeper::ManifestReader.load(FIXTURE_MANIFEST)

    assert_includes reader.gem_names, "internal-gem-one"
    assert_includes reader.gem_names, "internal-gem-two"
    assert_includes reader.gem_names, "other-internal-gem"
  end

  def test_find_by_name_returns_matching_gem
    reader = Gemkeeper::ManifestReader.load(FIXTURE_MANIFEST)
    gem = reader.find_by_name("internal-gem-two")

    assert_equal "internal-gem-two", gem[:name]
    assert_equal "https://github.com/company/internal-gem-two", gem[:repo]
  end

  def test_find_by_name_returns_nil_for_unknown_gem
    reader = Gemkeeper::ManifestReader.load(FIXTURE_MANIFEST)

    assert_nil reader.find_by_name("nonexistent-gem")
  end

  def test_raises_when_manifest_not_found
    assert_raises(Gemkeeper::ManifestNotFoundError) do
      Gemkeeper::ManifestReader.load(File.join(@temp_dir, "missing.yml"))
    end
  end

  def test_error_message_mentions_manifest
    err = assert_raises(Gemkeeper::ManifestNotFoundError) do
      Gemkeeper::ManifestReader.load(File.join(@temp_dir, "missing.yml"))
    end

    assert_match(/manifest/i, err.message)
  end
end
