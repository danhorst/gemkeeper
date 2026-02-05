# frozen_string_literal: true

require "integration_helper"

class TestGemBuilderIntegration < Minitest::Test
  include IntegrationHelper

  def setup
    @temp_dir = Dir.mktmpdir
    @output_dir = File.join(@temp_dir, "output")
    FileUtils.mkdir_p(@output_dir)

    # Copy fixture gem to temp location so we don't pollute fixtures
    @repo_path = File.join(@temp_dir, "test_gem")
    FileUtils.cp_r(test_gem_path, @repo_path)
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_build_creates_gem_file
    builder = Gemkeeper::GemBuilder.new(@repo_path)

    gem_path = builder.build

    assert File.exist?(gem_path)
    assert_match(/test_gem-0\.1\.0\.gem$/, gem_path)
  ensure
    FileUtils.rm_f(gem_path) if gem_path
  end

  def test_build_with_output_directory
    builder = Gemkeeper::GemBuilder.new(@repo_path, @output_dir)

    gem_path = builder.build

    assert File.exist?(gem_path)
    assert gem_path.start_with?(@output_dir)
    assert_equal "test_gem-0.1.0.gem", File.basename(gem_path)
  end

  def test_build_gem_is_valid
    builder = Gemkeeper::GemBuilder.new(@repo_path, @output_dir)
    gem_path = builder.build

    # Verify the gem is valid by checking its contents
    stdout, _stderr, status = Open3.capture3("gem", "spec", gem_path)

    assert status.success?, "Gem should be a valid gem file"
    assert_match(/name:\s*test_gem/, stdout)
    assert_match(/version:\s*0\.1\.0/, stdout)
  end

  def test_gem_name_matches_gemspec
    builder = Gemkeeper::GemBuilder.new(@repo_path)

    assert_equal "test_gem", builder.gem_name
  end

  def test_build_fails_without_gemspec
    empty_repo = File.join(@temp_dir, "empty_repo")
    FileUtils.mkdir_p(empty_repo)

    builder = Gemkeeper::GemBuilder.new(empty_repo)

    assert_raises(Gemkeeper::GemspecNotFoundError) do
      builder.build
    end
  end

  def test_build_fails_with_invalid_gemspec
    # Create a gem with an invalid gemspec
    invalid_repo = File.join(@temp_dir, "invalid_gem")
    FileUtils.mkdir_p(invalid_repo)

    File.write(File.join(invalid_repo, "invalid.gemspec"), <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name = "invalid"
        # Missing required fields like version, authors, summary
      end
    RUBY

    builder = Gemkeeper::GemBuilder.new(invalid_repo)

    assert_raises(Gemkeeper::BuildError) do
      builder.build
    end
  end
end
