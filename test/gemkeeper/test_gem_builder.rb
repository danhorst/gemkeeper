# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "fileutils"

class TestGemBuilder < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @repo_path = File.join(@temp_dir, "repo")
    FileUtils.mkdir_p(@repo_path)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_initialize
    builder = Gemkeeper::GemBuilder.new(@repo_path)

    assert_equal @repo_path, builder.repo_path
    assert_nil builder.output_dir
  end

  def test_initialize_with_output_dir
    output_dir = File.join(@temp_dir, "output")
    builder = Gemkeeper::GemBuilder.new(@repo_path, output_dir)

    assert_equal output_dir, builder.output_dir
  end

  def test_gem_name_returns_nil_when_no_gemspec
    builder = Gemkeeper::GemBuilder.new(@repo_path)

    assert_nil builder.gem_name
  end

  def test_gem_name_returns_name_from_gemspec
    gemspec_path = File.join(@repo_path, "my-gem.gemspec")
    File.write(gemspec_path, "# gemspec")

    builder = Gemkeeper::GemBuilder.new(@repo_path)

    assert_equal "my-gem", builder.gem_name
  end

  def test_build_raises_when_no_gemspec
    builder = Gemkeeper::GemBuilder.new(@repo_path)

    assert_raises(Gemkeeper::GemspecNotFoundError) do
      builder.build
    end
  end
end
