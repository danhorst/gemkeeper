# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "fileutils"

class TestGitRepository < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @repo_url = "https://github.com/example/repo.git"
    @local_path = File.join(@temp_dir, "repo")
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_initialize
    repo = Gemkeeper::GitRepository.new(@repo_url, @local_path)

    assert_equal @repo_url, repo.repo_url
    assert_equal @local_path, repo.local_path
  end

  def test_find_gemspec_returns_nil_when_no_repo
    repo = Gemkeeper::GitRepository.new(@repo_url, @local_path)

    assert_nil repo.find_gemspec
  end

  def test_find_gemspec_returns_path_when_exists
    FileUtils.mkdir_p(@local_path)
    gemspec_path = File.join(@local_path, "my-gem.gemspec")
    File.write(gemspec_path, "# gemspec")

    repo = Gemkeeper::GitRepository.new(@repo_url, @local_path)

    assert_equal gemspec_path, repo.find_gemspec
  end

  def test_current_version_extracts_from_gemspec
    FileUtils.mkdir_p(@local_path)
    gemspec_content = <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "my-gem"
        spec.version = "1.2.3"
      end
    RUBY
    File.write(File.join(@local_path, "my-gem.gemspec"), gemspec_content)

    repo = Gemkeeper::GitRepository.new(@repo_url, @local_path)

    assert_equal "1.2.3", repo.current_version
  end

  def test_current_version_extracts_from_version_constant
    FileUtils.mkdir_p(@local_path)
    gemspec_content = <<~RUBY
      Gem::Specification.new do |spec|
        spec.name = "my-gem"
        VERSION = "2.0.0"
      end
    RUBY
    File.write(File.join(@local_path, "my-gem.gemspec"), gemspec_content)

    repo = Gemkeeper::GitRepository.new(@repo_url, @local_path)

    assert_equal "2.0.0", repo.current_version
  end
end
