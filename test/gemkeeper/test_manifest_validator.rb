# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

class TestManifestValidator < Minitest::Test
  FIXTURE_MANIFEST = File.expand_path("../fixtures/sample_manifest.yml", __dir__)

  def setup
    @tmpdir = Dir.mktmpdir
    @output = StringIO.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def validator(path)
    Gemkeeper::ManifestValidator.new(path)
  end

  def write_manifest(content)
    path = File.join(@tmpdir, "manifest.yml")
    File.write(path, content)
    path
  end

  def validate(path, resolve: false)
    validator(path).validate(resolve:, output: @output)
  end

  def test_valid_fixture_manifest_has_no_errors
    assert_empty validate(FIXTURE_MANIFEST)
  end

  def test_returns_error_when_file_missing
    errors = validate(File.join(@tmpdir, "missing.yml"))

    assert_equal 1, errors.size
    assert_match(/File not found/, errors.first)
  end

  def test_returns_error_on_invalid_yaml
    path = write_manifest("gems: [unclosed")
    errors = validate(path)

    assert_equal 1, errors.size
    assert_match(/Invalid YAML/, errors.first)
  end

  def test_empty_manifest_is_valid
    path = write_manifest("gems: []")

    assert_empty validate(path)
  end

  def test_returns_error_when_name_missing
    path = write_manifest(<<~YAML)
      gems:
        - repo: git@github.com:org/my-gem.git
    YAML

    errors = validate(path)

    assert(errors.any? { |e| e.include?("missing name") })
  end

  def test_returns_error_when_repo_missing
    path = write_manifest(<<~YAML)
      gems:
        - name: my-gem
    YAML

    errors = validate(path)

    assert(errors.any? { |e| e.include?("missing repo") })
  end

  def test_returns_error_when_repo_is_not_a_git_url
    path = write_manifest(<<~YAML)
      gems:
        - name: my-gem
          repo: not-a-url
    YAML

    errors = validate(path)

    assert(errors.any? { |e| e.include?("does not look like a git URL") })
  end

  def test_accepts_ssh_git_url
    path = write_manifest(<<~YAML)
      gems:
        - name: my-gem
          repo: git@github.com:org/my-gem.git
    YAML

    assert_empty validate(path)
  end

  def test_accepts_https_git_url
    path = write_manifest(<<~YAML)
      gems:
        - name: my-gem
          repo: https://github.com/org/my-gem.git
    YAML

    assert_empty validate(path)
  end

  def test_accepts_ssh_scheme_url
    path = write_manifest(<<~YAML)
      gems:
        - name: my-gem
          repo: ssh://git@github.com/org/my-gem.git
    YAML

    assert_empty validate(path)
  end

  def test_returns_error_for_duplicate_names
    path = write_manifest(<<~YAML)
      gems:
        - name: my-gem
          repo: git@github.com:org/my-gem.git
        - name: my-gem
          repo: git@github.com:org/my-gem-fork.git
    YAML

    errors = validate(path)

    assert(errors.any? { |e| e.include?("duplicate name") })
  end

  def test_returns_error_when_gems_is_not_a_list
    path = write_manifest(<<~YAML)
      gems: not-a-list
    YAML

    errors = validate(path)

    assert(errors.any? { |e| e.include?("gems must be a list") })
  end

  def test_returns_error_for_invalid_source_url
    path = write_manifest(<<~YAML)
      source_url: not-a-url
      gems: []
    YAML

    errors = validate(path)

    assert(errors.any? { |e| e.include?("source_url") })
  end

  def test_accepts_valid_source_url
    path = write_manifest(<<~YAML)
      source_url: https://example.com/gems
      gems: []
    YAML

    assert_empty validate(path)
  end

  def test_static_errors_short_circuit_resolve
    path = write_manifest("not: valid: yaml: ][")
    errors = validate(path, resolve: true)

    assert_equal 1, errors.size
    assert_match(/Invalid YAML/, errors.first)
    assert_empty @output.string
  end

  def test_resolve_reports_unreachable_repo
    path = write_manifest(<<~YAML)
      gems:
        - name: my-gem
          repo: git@invalid.example.test:org/my-gem.git
    YAML

    errors = validate(path, resolve: true)

    assert(errors.any? { |e| e.include?("my-gem") })
    assert_match(/FAILED|timed out/, @output.string)
  end
end
