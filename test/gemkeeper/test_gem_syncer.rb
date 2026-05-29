# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "rubygems/package"

class TestGemSyncer < Minitest::Test
  ConfigDouble = Struct.new(:gems_path, :repos_path)

  class FakeUploader
    attr_reader :uploaded

    def initialize(present:)
      @present  = present
      @uploaded = []
    end

    def serves?(_name, _version) = @present

    def upload(path)
      @uploaded << path
      { success: true, message: "Uploaded #{File.basename(path)}" }
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Artifact reuse (FR-1.3) ───────────────────────────────────────────────

  def test_reusable_artifact_true_for_matching_gem
    path = build_artifact(@tmpdir, "my-gem", "1.0.0")
    assert syncer_with.send(:reusable_artifact?, path, "my-gem", "1.0.0")
  end

  def test_reusable_artifact_false_for_mismatched_name
    path = build_artifact(@tmpdir, "other-gem", "1.0.0")
    refute syncer_with.send(:reusable_artifact?, path, "my-gem", "1.0.0")
  end

  def test_reusable_artifact_false_for_corrupt_file
    path = File.join(@tmpdir, "broken-1.0.0.gem")
    File.write(path, "not a gem")
    refute syncer_with.send(:reusable_artifact?, path, "broken", "1.0.0")
  end

  def test_reusable_artifact_false_when_absent
    path = File.join(@tmpdir, "absent-1.0.0.gem")
    refute syncer_with.send(:reusable_artifact?, path, "absent", "1.0.0")
  end

  # ── sync() orchestration (FR-1.1, FR-1.3) ─────────────────────────────────

  def test_sync_skips_when_server_already_serves
    uploader = FakeUploader.new(present: true)
    syncer = syncer_with(uploader:)

    result = nil
    Gemkeeper::GitRepository.stub(:new, ->(*) { flunk("must not fetch when server already serves") }) do
      capture_io { result = syncer.sync(gem_def(name: "my-gem", version: "1.0.0")) }
    end

    assert_equal :skipped, result
    assert_empty uploader.uploaded
  end

  def test_sync_reuploads_existing_artifact_without_rebuild
    gems_path = File.join(@tmpdir, "gems")
    build_artifact(gems_path, "my-gem", "1.0.0")
    uploader = FakeUploader.new(present: false)
    syncer = syncer_with(uploader:, gems_path:)

    result = nil
    Gemkeeper::GitRepository.stub(:new, ->(*) { flunk("must not clone when a valid artifact exists") }) do
      Gemkeeper::GemBuilder.stub(:new, ->(*) { flunk("must not build when a valid artifact exists") }) do
        capture_io { result = syncer.sync(gem_def(name: "my-gem", version: "1.0.0")) }
      end
    end

    assert_equal :synced, result
    assert_equal 1, uploader.uploaded.size
    assert_match(/my-gem-1\.0\.0\.gem\z/, uploader.uploaded.first)
  end

  private

  def gem_def(attrs)
    Gemkeeper::Configuration::GemDefinition.new(attrs)
  end

  def missing_manifest
    Gemkeeper::ManifestReader.load(File.join(@tmpdir, "absent.yml"))
  end

  def syncer_with(uploader: nil, gems_path: @tmpdir)
    config = ConfigDouble.new(gems_path, File.join(@tmpdir, "repos"))
    Gemkeeper::GemSyncer.new(config, uploader, manifest: missing_manifest)
  end

  def build_artifact(dir, name, version)
    spec = Gem::Specification.new do |s|
      s.name     = name
      s.version  = version
      s.summary  = "Test gem"
      s.authors  = ["Test"]
      s.files    = []
    end
    FileUtils.mkdir_p(dir)
    Dir.chdir(dir) { Gem::Package.build(spec) }
    File.join(dir, "#{name}-#{version}.gem")
  end
end
