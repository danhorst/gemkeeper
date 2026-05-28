# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestBundlerMirrorConfigurator < Minitest::Test
  def test_no_output_when_candidates_empty
    out = StringIO.new
    Gemkeeper::BundlerMirrorConfigurator.new([], port: 9292, global: false).configure(output: out)
    assert_empty out.string
  end

  def test_no_output_when_only_git_sources
    candidates = [{ name: "my-gem", source_type: :git, repo: "git@github.com:org/my-gem.git" }]
    out = StringIO.new
    Gemkeeper::BundlerMirrorConfigurator.new(candidates, port: 9292, global: false).configure(output: out)
    assert_empty out.string
  end

  def test_skipped_source_produces_no_mirror
    # Simulate all gems from a private registry having been skipped:
    # the caller filters out unresolved candidates before constructing the configurator.
    manifest_candidates = [
      { name: "resolved-gem", source_type: :private_gem, remote: "https://rubygems.pkg.github.com/org/" }
    ]
    skipped_candidates = [
      { name: "skipped-gem", source_type: :private_gem, remote: "https://gems.example.com/" }
    ]

    tmpdir = Dir.mktmpdir
    manifest = Gemkeeper::ManifestReader.load(File.join(tmpdir, "manifest.yml"))
    manifest.add_mapping(name: "resolved-gem", repo: "git@github.com:org/resolved-gem.git")

    resolved = (manifest_candidates + skipped_candidates).select { |c| manifest.repo_for(c[:name]) }

    captured = StringIO.new
    configure_with_stub(resolved, port: 9292, global: false, output: captured)

    assert_match(/rubygems\.pkg\.github\.com/, captured.string)
    refute_match(/gems\.example\.com/, captured.string)
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  private

  def configure_with_stub(candidates, port:, global:, output:)
    configurator = Gemkeeper::BundlerMirrorConfigurator.new(candidates, port:, global:)
    configurator.define_singleton_method(:configure_mirror) do |remote, out|
      out.puts "Configured: bundle config set --local mirror.#{remote} http://localhost:#{port}"
    end
    configurator.configure(output:)
  end
end
