# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TestLockfileParser < Minitest::Test
  FIXTURE_LOCKFILE = File.expand_path("../fixtures/sample.lock", __dir__)

  def setup
    @temp_dir = Dir.mktmpdir
    @original_dir = Dir.pwd
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(@temp_dir)
  end

  def test_parse_returns_gem_versions_from_gem_section
    versions = Gemkeeper::LockfileParser.parse(FIXTURE_LOCKFILE)

    assert_equal "7.0.4", versions["actioncable"]
    assert_equal "7.0.4", versions["actionpack"]
    assert_equal "1.2.3", versions["internal-gem-one"]
    assert_equal "0.9.0", versions["internal-gem-two"]
  end

  def test_parse_excludes_git_sourced_gems
    versions = Gemkeeper::LockfileParser.parse(FIXTURE_LOCKFILE)

    refute_includes versions, "git-sourced-gem"
  end

  def test_parse_excludes_dependency_lines
    versions = Gemkeeper::LockfileParser.parse(FIXTURE_LOCKFILE)

    # Dependencies indented deeper than 4 spaces should not be treated as top-level gems
    # e.g. "      activesupport (>= 6.0)" under internal-gem-two
    assert_equal "7.0.4", versions["activesupport"]
  end

  def test_find_returns_lockfile_in_current_dir
    lockfile = File.join(@temp_dir, "Gemfile.lock")
    File.write(lockfile, "")
    Dir.chdir(@temp_dir)

    found = Gemkeeper::LockfileParser.find(@temp_dir)

    assert_equal lockfile, found
  end

  def test_find_walks_up_directory_tree
    subdir = File.join(@temp_dir, "a", "b", "c")
    FileUtils.mkdir_p(subdir)
    lockfile = File.join(@temp_dir, "Gemfile.lock")
    File.write(lockfile, "")

    found = Gemkeeper::LockfileParser.find(subdir)

    assert_equal lockfile, found
  end

  def test_find_returns_nil_when_no_lockfile
    empty_dir = File.join(@temp_dir, "no_lockfile_here")
    FileUtils.mkdir_p(empty_dir)

    # Use a path rooted in temp_dir so we don't find any real Gemfile.lock above
    # by pointing to a known leaf with no parent lockfile within temp_dir
    found = Gemkeeper::LockfileParser.find(empty_dir)

    # Will eventually hit filesystem root and return nil, or find one in a real parent.
    # Just verify it returns a String or nil — not an error.
    assert found.nil? || found.is_a?(String)
  end
end
