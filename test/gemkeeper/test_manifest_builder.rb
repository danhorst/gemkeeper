# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

class TestManifestBuilder < Minitest::Test
  FIXTURE_LOCKFILE = File.expand_path("../fixtures/sample.lock", __dir__)

  def setup
    @tmpdir = Dir.mktmpdir
    @manifest = Gemkeeper::ManifestReader.load(File.join(@tmpdir, "manifest.yml"))
    @output = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def build(lockfile_path: FIXTURE_LOCKFILE, manifest: @manifest, input: StringIO.new(""))
    Gemkeeper::ManifestBuilder.build(lockfile_path:, manifest:, input:, output: @output)
  end

  def tty_input(content)
    StringIO.new(content).tap { |io| io.define_singleton_method(:isatty) { true } }
  end

  def lockfile_with(content)
    path = File.join(@tmpdir, "Gemfile.lock")
    File.write(path, content)
    path
  end

  def test_result_is_empty_when_lockfile_has_no_internal_sources
    path = lockfile_with(<<~LOCK)
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

    result = build(lockfile_path: path)

    assert result.empty?
    assert_equal 0, result.added_count
  end

  def test_git_source_is_added_automatically
    build

    assert_equal "git@github.com:company/git-sourced-gem.git", @manifest.repo_for("git-sourced-gem")
  end

  def test_private_gem_source_is_inferred_and_added
    build

    assert @manifest.repo_for("internal-gem-one")
    assert @manifest.repo_for("internal-gem-two")
  end

  def test_added_count_reflects_new_mappings
    result = build

    assert_equal result.added_count, @manifest.gems.size
    assert result.added_count.positive?
  end

  def test_already_mapped_gem_increments_already_mapped_count
    @manifest.add_mapping(name: "internal-gem-one", repo: "https://github.com/company/internal-gem-one")

    result = build

    assert_equal 1, result.already_mapped_count
    assert_equal "https://github.com/company/internal-gem-one", @manifest.repo_for("internal-gem-one")
  end

  def test_any_changes_true_when_gems_added
    result = build

    assert result.any_changes?
  end

  def test_any_changes_false_when_all_already_mapped
    path = lockfile_with(<<~LOCK)
      GIT
        remote: git@github.com:org/my-gem.git
        revision: abc1234
        specs:
          my-gem (1.0.0)
      PLATFORMS
        ruby
      DEPENDENCIES
        my-gem!
      BUNDLED WITH
         2.4.10
    LOCK
    @manifest.add_mapping(name: "my-gem", repo: "git@github.com:org/my-gem.git")

    result = build(lockfile_path: path)

    refute result.any_changes?
    assert_equal 1, result.already_mapped_count
    assert_equal 0, result.added_count
  end

  def test_interactively_skipped_gem_increments_skipped_count
    path = lockfile_with(<<~LOCK)
      GEM
        remote: https://gems.example.com/
        specs:
          mystery-gem (1.0.0)
      PLATFORMS
        ruby
      DEPENDENCIES
        mystery-gem
      BUNDLED WITH
         2.4.10
    LOCK

    result = build(lockfile_path: path, input: tty_input("\n"))

    assert_equal 1, result.skipped_count
    assert_equal 0, result.added_count
    assert_nil @manifest.repo_for("mystery-gem")
  end

  def test_raises_for_unknown_remote_in_non_interactive_mode
    path = lockfile_with(<<~LOCK)
      GEM
        remote: https://gems.example.com/
        specs:
          mystery-gem (1.0.0)
      PLATFORMS
        ruby
      DEPENDENCIES
        mystery-gem
      BUNDLED WITH
         2.4.10
    LOCK

    assert_raises(Gemkeeper::UnresolvableGemError) { build(lockfile_path: path) }
  end
end
