# frozen_string_literal: true

require "integration_helper"

class TestGitRepositoryIntegration < Minitest::Test
  include IntegrationHelper

  def setup
    @temp_dir = Dir.mktmpdir
    @remote_repo = File.join(@temp_dir, "remote.git")
    @local_repo = File.join(@temp_dir, "local")

    # Create a bare "remote" repository
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

  def test_find_gemspec_returns_path
    repo = Gemkeeper::GitRepository.new(@remote_repo, @local_repo)
    repo.clone_or_pull

    gemspec = repo.find_gemspec

    assert gemspec.end_with?("test.gemspec")
    assert File.exist?(gemspec)
  end

  private

  def create_bare_remote_repo
    # Create a working repo first
    work_dir = File.join(@temp_dir, "work")
    FileUtils.mkdir_p(work_dir)

    Dir.chdir(work_dir) do
      system("git", "init", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "config", "user.email", "test@example.com", out: File::NULL, err: File::NULL)
      system("git", "config", "user.name", "Test User", out: File::NULL, err: File::NULL)

      # Create a gemspec
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

    # Clone to bare repo
    system("git", "clone", "--bare", work_dir, @remote_repo, out: File::NULL, err: File::NULL)
    FileUtils.rm_rf(work_dir)
  end

  def add_commit_to_remote(message)
    # Clone remote, add commit, push
    work_dir = File.join(@temp_dir, "push_work")
    system("git", "clone", @remote_repo, work_dir, out: File::NULL, err: File::NULL)

    Dir.chdir(work_dir) do
      system("git", "config", "user.email", "test@example.com", out: File::NULL, err: File::NULL)
      system("git", "config", "user.name", "Test User", out: File::NULL, err: File::NULL)
      File.write("new_file.txt", message)
      system("git", "add", ".", out: File::NULL, err: File::NULL)
      system("git", "commit", "-m", message, out: File::NULL, err: File::NULL)
      system("git", "push", out: File::NULL, err: File::NULL)
    end

    FileUtils.rm_rf(work_dir)
  end

  def create_tag_in_remote(tag_name)
    work_dir = File.join(@temp_dir, "tag_work")
    system("git", "clone", @remote_repo, work_dir, out: File::NULL, err: File::NULL)

    Dir.chdir(work_dir) do
      system("git", "config", "user.email", "test@example.com", out: File::NULL, err: File::NULL)
      system("git", "config", "user.name", "Test User", out: File::NULL, err: File::NULL)
      system("git", "tag", tag_name, out: File::NULL, err: File::NULL)
      system("git", "push", "--tags", out: File::NULL, err: File::NULL)
    end

    FileUtils.rm_rf(work_dir)

    # Also fetch in local
    return unless File.directory?(@local_repo)

    Dir.chdir(@local_repo) do
      system("git", "fetch", "--all", "--tags", out: File::NULL, err: File::NULL)
    end
  end

  def get_head_commit(repo_path)
    Dir.chdir(repo_path) do
      `git rev-parse HEAD`.strip
    end
  end

  def get_current_ref(repo_path)
    Dir.chdir(repo_path) do
      `git describe --tags --always 2>/dev/null || git rev-parse --short HEAD`.strip
    end
  end

  def get_current_branch(repo_path)
    Dir.chdir(repo_path) do
      `git rev-parse --abbrev-ref HEAD`.strip
    end
  end
end
