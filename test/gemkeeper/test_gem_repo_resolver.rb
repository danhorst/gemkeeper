# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

class TestGemRepoResolver < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @manifest = Gemkeeper::ManifestReader.load(File.join(@tmpdir, "manifest.yml"))
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def resolver(candidates:, input: StringIO.new(""), output: StringIO.new)
    Gemkeeper::GemRepoResolver.new(candidates:, manifest: @manifest, input:, output:)
  end

  def tty_input(content)
    StringIO.new(content).tap { |io| io.define_singleton_method(:isatty) { true } }
  end

  def git_candidate(name: "my-gem", repo: "git@github.com:org/my-gem.git")
    { name:, repo:, source_type: :git }
  end

  def private_gem_candidate(name: "my-gem", remote: "https://rubygems.pkg.github.com/org/")
    { name:, remote:, source_type: :private_gem }
  end

  def test_git_sources_are_added_automatically
    resolver(candidates: [git_candidate]).resolve!

    assert_equal "git@github.com:org/my-gem.git", @manifest.repo_for("my-gem")
  end

  def test_already_mapped_gems_are_skipped
    @manifest.add_mapping(name: "my-gem", repo: "git@github.com:org/existing.git")

    resolver(candidates: [git_candidate(repo: "git@github.com:org/other.git")]).resolve!

    assert_equal "git@github.com:org/existing.git", @manifest.repo_for("my-gem")
  end

  def test_non_interactive_infers_github_packages_repo
    resolver(candidates: [private_gem_candidate], output: StringIO.new).resolve!

    assert_equal "git@github.com:org/my-gem.git", @manifest.repo_for("my-gem")
  end

  def test_non_interactive_raises_for_unknown_remote
    candidate = private_gem_candidate(remote: "https://gems.example.com/")

    assert_raises(Gemkeeper::UnresolvableGemError) do
      resolver(candidates: [candidate]).resolve!
    end
  end

  def test_interactive_blank_accepts_inferred
    resolver(candidates: [private_gem_candidate], input: tty_input("\n")).resolve!

    assert_equal "git@github.com:org/my-gem.git", @manifest.repo_for("my-gem")
  end

  def test_interactive_blank_with_no_inferred_skips_gem
    candidate = private_gem_candidate(remote: "https://gems.example.com/")
    output = StringIO.new

    resolver(candidates: [candidate], input: tty_input("\n"), output:).resolve!

    assert_nil @manifest.repo_for("my-gem")
    assert_match(/Skipping/, output.string)
  end

  def test_interactive_skip_keyword_skips_gem
    output = StringIO.new

    resolver(candidates: [private_gem_candidate], input: tty_input("skip\n"), output:).resolve!

    assert_nil @manifest.repo_for("my-gem")
    assert_match(/Skipping/, output.string)
  end

  def test_interactive_custom_url_is_used
    input = tty_input("git@github.com:org/custom.git\n")

    resolver(candidates: [private_gem_candidate], input:).resolve!

    assert_equal "git@github.com:org/custom.git", @manifest.repo_for("my-gem")
  end
end
