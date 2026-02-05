# frozen_string_literal: true

require "test_helper"
require "open3"
require "tempfile"
require "fileutils"
require "timeout"

module IntegrationHelper
  FIXTURES_PATH = File.expand_path("fixtures", __dir__)
  PROJECT_ROOT = File.expand_path("..", __dir__)
  GEMKEEPER_BIN = File.join(PROJECT_ROOT, "exe", "gemkeeper")

  def fixtures_path
    FIXTURES_PATH
  end

  def test_gem_path
    File.join(FIXTURES_PATH, "test_gem")
  end

  def run_gemkeeper(*args, env: {}, allow_failure: false)
    cmd = ["bundle", "exec", "ruby", GEMKEEPER_BIN, *args]
    full_env = ENV.to_h.merge(env)

    stdout, stderr, status = Open3.capture3(full_env, *cmd, chdir: PROJECT_ROOT)

    unless allow_failure || status.success?
      raise "Command failed: #{cmd.join(" ")}\nSTDOUT: #{stdout}\nSTDERR: #{stderr}"
    end

    { stdout: stdout, stderr: stderr, status: status }
  end

  def with_temp_dir
    temp_dir = Dir.mktmpdir
    yield temp_dir
  ensure
    FileUtils.rm_rf(temp_dir)
  end

  def with_config(config_hash)
    with_temp_dir do |temp_dir|
      config_path = File.join(temp_dir, "gemkeeper.yml")
      File.write(config_path, config_hash.to_yaml)
      yield temp_dir, config_path
    end
  end

  def wait_for_condition?(timeout: 10, interval: 0.5)
    deadline = Time.now + timeout
    while Time.now < deadline
      return true if yield

      sleep interval
    end
    false
  end
end
