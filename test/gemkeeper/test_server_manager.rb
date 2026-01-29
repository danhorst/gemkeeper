# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "fileutils"

class TestServerManager < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@temp_dir)

    File.write("gemkeeper.yml", <<~YAML)
      port: 19292
      gems_path: #{@temp_dir}/gems
    YAML

    @config = Gemkeeper::Configuration.load
  end

  def teardown
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(@temp_dir)
  end

  def test_initialize
    manager = Gemkeeper::ServerManager.new(@config)

    assert_equal @config, manager.config
  end

  def test_running_returns_false_when_no_pid_file
    manager = Gemkeeper::ServerManager.new(@config)

    refute manager.running?
  end

  def test_running_returns_false_when_pid_file_has_dead_process
    # Write a PID that definitely doesn't exist
    FileUtils.mkdir_p(File.dirname(@config.pid_file))
    File.write(@config.pid_file, "999999999")

    manager = Gemkeeper::ServerManager.new(@config)

    refute manager.running?
  end

  def test_status_returns_not_running_hash
    manager = Gemkeeper::ServerManager.new(@config)
    status = manager.status

    refute status[:running]
    assert_nil status[:pid]
    assert_nil status[:url]
  end

  def test_stop_raises_when_not_running
    manager = Gemkeeper::ServerManager.new(@config)

    assert_raises(Gemkeeper::ServerNotRunningError) do
      manager.stop
    end
  end
end
