# frozen_string_literal: true

require "integration_helper"

class TestGitRepositoryIntegration < Minitest::Test
  include IntegrationHelper

  def setup
    @temp_dir = Dir.mktmpdir
    @remote_repo = File.join(@temp_dir, "remote.git")
    @require_remote = File.join(@temp_dir, "require_remote.git")
    @local_repo = File.join(@temp_dir, "local")

    create_bare_remote_repo
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_clone_creates_local_repo
    repo = Gemkeeper::GitRepository.new(@remote_repo, @local_repo)

    repo.clone_or_pull

    assert File.directory?(@local_repo), "Local repo should be created"
    assert File.directory?(File.join(@local_repo, ".git")), "Should be a git repo"
    assert File.exist?(File.join(@local_repo, "test.gemspec")), "Should have cloned files"
  end

  def test_clone_or_pull_pulls_when_exists
    repo = Gemkeeper::GitRepository.new(@remote_repo, @local_repo)

    # First clone
    repo.clone_or_pull
    original_commit = get_head_commit(@local_repo)

    # Add a commit to "remote"
    add_commit_to_remote("Second commit")

    # Pull should get the new commit
    repo.clone_or_pull
    new_commit = get_head_commit(@local_repo)

    refute_equal original_commit, new_commit, "Should have pulled new commit"
  end

  def test_checkout_version_with_tag
    repo = Gemkeeper::GitRepository.new(@remote_repo, @local_repo)
    repo.clone_or_pull

    # Create a tag in remote
    create_tag_in_remote("v1.0.0")

    # Checkout the tag
    repo.checkout_version("v1.0.0")

    # Verify we're at the tag
    current_ref = get_current_ref(@local_repo)
    assert_match(/v1\.0\.0|HEAD/, current_ref)
  end

  def test_checkout_version_latest_stays_on_trunk
    repo = Gemkeeper::GitRepository.new(@remote_repo, @local_repo)
    repo.clone_or_pull

    repo.checkout_version("latest")

    # Should be on main
    current_branch = get_current_branch(@local_repo)
    assert_includes %w[main master], current_branch
  end

  def test_current_version_from_gemspec_with_version_attribute
    repo = Gemkeeper::GitRepository.new(@remote_repo, @local_repo)
    repo.clone_or_pull

    version = repo.current_version

    assert_equal "0.1.0", version
  end

  def test_checkout_version_bare_semver_finds_v_prefixed_tag
    repo = Gemkeeper::GitRepository.new(@remote_repo, @local_repo)
    repo.clone_or_pull
    create_tag_in_remote("v2.0.0")

    repo.checkout_version("2.0.0")

    current_ref = get_current_ref(@local_repo)
    assert_match(/v2\.0\.0|2\.0\.0|HEAD/, current_ref)
  end

  def test_current_version_from_require_relative
    create_remote_with_require_relative_version
    repo = Gemkeeper::GitRepository.new(@require_remote, @local_repo)
    repo.clone_or_pull

    assert_equal "1.5.0", repo.current_version
  end

  def test_find_gemspec_returns_path
    repo = Gemkeeper::GitRepository.new(@remote_repo, @local_repo)
    repo.clone_or_pull

    gemspec = repo.find_gemspec

    assert gemspec.end_with?("test.gemspec")
    assert File.exist?(gemspec)
  end

  private

  def configure_git
    system("git", "config", "user.email", "test@example.com", out: File::NULL, err: File::NULL)
    system("git", "config", "user.name", "Test User", out: File::NULL, err: File::NULL)
    system("git", "config", "commit.gpgSign", "false", out: File::NULL, err: File::NULL)
    system("git", "config", "tag.gpgSign", "false", out: File::NULL, err: File::NULL)
  end

  def with_clone(name)
    work_dir = File.join(@temp_dir, name)
    system("git", "clone", @remote_repo, work_dir, out: File::NULL, err: File::NULL)
    Dir.chdir(work_dir) do
      configure_git
      yield
    end
  ensure
    FileUtils.rm_rf(work_dir)
  end

  def create_bare_remote_repo
    work_dir = File.join(@temp_dir, "work")
    FileUtils.mkdir_p(work_dir)
    Dir.chdir(work_dir) do
      system("git", "init", "-b", "main", out: File::NULL, err: File::NULL)
      configure_git
      File.write("test.gemspec", <<~RUBY)
        Gem::Specification.new do |spec|
          spec.name = "test"
          spec.version = "0.1.0"
          spec.authors = ["Test"]
          spec.summary = "Test gem"
        end
      RUBY
      system("git", "add", ".", out: File::NULL, err: File::NULL)
      system("git", "commit", "-m", "Initial commit", out: File::NULL, err: File::NULL)
    end
    system("git", "clone", "--bare", work_dir, @remote_repo, out: File::NULL, err: File::NULL)
    FileUtils.rm_rf(work_dir)
  end

  def add_commit_to_remote(message)
    with_clone("push_work") do
      File.write("new_file.txt", message)
      system("git", "add", ".", out: File::NULL, err: File::NULL)
      system("git", "commit", "-m", message, out: File::NULL, err: File::NULL)
      system("git", "push", out: File::NULL, err: File::NULL)
    end
  end

  def create_tag_in_remote(tag_name)
    with_clone("tag_work") do
      system("git", "tag", tag_name, out: File::NULL, err: File::NULL)
      system("git", "push", "--tags", out: File::NULL, err: File::NULL)
    end

    return unless File.directory?(@local_repo)

    Dir.chdir(@local_repo) do
      system("git", "fetch", "--all", "--tags", out: File::NULL, err: File::NULL)
    end
  end

  def create_remote_with_require_relative_version
    work_dir = File.join(@temp_dir, "require_work")
    FileUtils.mkdir_p(File.join(work_dir, "lib", "my_gem"))
    Dir.chdir(work_dir) do
      system("git", "init", "-b", "main", out: File::NULL, err: File::NULL)
      configure_git
      File.write("my_gem.gemspec", <<~RUBY)
        require_relative "lib/my_gem/version"
        Gem::Specification.new do |spec|
          spec.name = "my-gem"
          spec.version = MyGem::VERSION
          spec.summary = "Test"
        end
      RUBY
      File.write("lib/my_gem/version.rb", <<~RUBY)
        module MyGem
          VERSION = "1.5.0"
        end
      RUBY
      system("git", "add", ".", out: File::NULL, err: File::NULL)
      system("git", "commit", "-m", "Initial commit", out: File::NULL, err: File::NULL)
    end
    system("git", "clone", "--bare", work_dir, @require_remote, out: File::NULL, err: File::NULL)
    FileUtils.rm_rf(work_dir)
  end

  def get_head_commit(repo_path)
    Dir.chdir(repo_path) { `git rev-parse HEAD`.strip }
  end

  def get_current_ref(repo_path)
    Dir.chdir(repo_path) { `git describe --tags --always 2>/dev/null || git rev-parse --short HEAD`.strip }
  end

  def get_current_branch(repo_path)
    Dir.chdir(repo_path) { `git rev-parse --abbrev-ref HEAD`.strip }
  end
end
