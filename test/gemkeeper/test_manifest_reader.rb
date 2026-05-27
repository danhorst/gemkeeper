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

  def test_repo_for_returns_url_for_known_gem
    reader = Gemkeeper::ManifestReader.load(FIXTURE_MANIFEST)

    assert_equal "https://github.com/company/internal-gem-one", reader.repo_for("internal-gem-one")
  end

  def test_repo_for_returns_nil_for_unknown_gem
    reader = Gemkeeper::ManifestReader.load(FIXTURE_MANIFEST)

    assert_nil reader.repo_for("nonexistent-gem")
  end

  def test_returns_empty_manifest_when_file_missing
    reader = Gemkeeper::ManifestReader.load(File.join(@temp_dir, "missing.yml"))

    assert_empty reader.gems
  end

  def test_add_mapping_adds_new_entry
    reader = Gemkeeper::ManifestReader.load(File.join(@temp_dir, "missing.yml"))
    reader.add_mapping(name: "my-gem", repo: "git@github.com:org/my-gem.git")

    assert_equal 1, reader.gems.size
    assert_equal "my-gem", reader.gems[0][:name]
  end

  def test_add_mapping_is_idempotent_for_same_entry
    reader = Gemkeeper::ManifestReader.load(File.join(@temp_dir, "missing.yml"))
    reader.add_mapping(name: "my-gem", repo: "git@github.com:org/my-gem.git")
    reader.add_mapping(name: "my-gem", repo: "git@github.com:org/my-gem.git")

    assert_equal 1, reader.gems.size
  end

  def test_add_mapping_raises_on_repo_conflict
    reader = Gemkeeper::ManifestReader.load(File.join(@temp_dir, "missing.yml"))
    reader.add_mapping(name: "my-gem", repo: "git@github.com:org/my-gem.git")

    assert_raises(Gemkeeper::ManifestConflictError) do
      reader.add_mapping(name: "my-gem", repo: "git@github.com:org/other-repo.git")
    end
  end

  def test_save_writes_yaml_file
    path = File.join(@temp_dir, "manifest.yml")
    reader = Gemkeeper::ManifestReader.load(path)
    reader.add_mapping(name: "my-gem", repo: "git@github.com:org/my-gem.git")
    reader.save(path)

    assert File.exist?(path)
    data = YAML.safe_load_file(path)
    assert_equal [{ "name" => "my-gem", "repo" => "git@github.com:org/my-gem.git" }], data["gems"]
  end

  def test_save_creates_parent_directory
    path = File.join(@temp_dir, "subdir", "manifest.yml")
    reader = Gemkeeper::ManifestReader.load(path)
    reader.save(path)

    assert File.exist?(path)
  end
end
