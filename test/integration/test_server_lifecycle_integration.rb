# frozen_string_literal: true

require "integration_helper"
require "net/http"

class TestServerLifecycleIntegration < Minitest::Test
  include IntegrationHelper

  def setup
    @temp_dir = Dir.mktmpdir
    @original_dir = Dir.pwd
    Dir.chdir(@temp_dir)

    # Use a high port to avoid conflicts
    @port = rand(19_292..20_291)
    @config_path = File.join(@temp_dir, "gemkeeper.yml")

    File.write(@config_path, {
      "port" => @port,
      "gems_path" => File.join(@temp_dir, "gems"),
      "repos_path" => File.join(@temp_dir, "repos")
    }.to_yaml)

    @config = Gemkeeper::Configuration.load(@config_path)
    @manager = Gemkeeper::ServerManager.new(@config)
  end

  def teardown
    # Ensure server is stopped
    stop_server_if_running

    Dir.chdir(@original_dir)
    FileUtils.rm_rf(@temp_dir)
  end

  def test_server_start_and_stop_lifecycle
    refute @manager.running?, "Server should not be running initially"

    # Start the server
    @manager.start

    assert @manager.running?, "Server should be running after start"
    assert File.exist?(@config.pid_file), "PID file should exist"

    # Verify server is accessible
    assert server_responds?, "Server should respond to HTTP requests"

    # Stop the server
    @manager.stop

    refute @manager.running?, "Server should not be running after stop"
    refute File.exist?(@config.pid_file), "PID file should be cleaned up"
  end

  def test_server_status_while_running
    @manager.start

    status = @manager.status

    assert status[:running]
    assert_kind_of Integer, status[:pid]
    assert status[:pid].positive?
    assert_equal @config.geminabox_url, status[:url]
  end

  def test_server_start_twice_raises_error
    @manager.start

    assert_raises(Gemkeeper::ServerAlreadyRunningError) do
      @manager.start
    end
  end

  def test_server_generates_config_ru
    @manager.start

    assert File.exist?(@config.config_ru_path), "config.ru should be generated"

    content = File.read(@config.config_ru_path)
    assert_match(/Geminabox\.data/, content)
    assert_match(/Geminabox\.rubygems_proxy\s*=\s*true/, content)
  end

  def test_server_creates_gems_directory
    @manager.start

    assert File.directory?(@config.gems_path), "gems directory should be created"
  end

  def test_cli_server_start_stop_status
    # Start via CLI
    result = run_gemkeeper("server", "start", "--config", @config_path)
    assert_match(/started/, result[:stdout])

    # Check status via CLI
    result = run_gemkeeper("server", "status", "--config", @config_path)
    assert_match(/is running/, result[:stdout])
    assert_match(/PID:/, result[:stdout])

    # Stop via CLI
    result = run_gemkeeper("server", "stop", "--config", @config_path)
    assert_match(/stopped/, result[:stdout])

    # Verify stopped via CLI
    result = run_gemkeeper("server", "status", "--config", @config_path)
    assert_match(/not running/, result[:stdout])
  end

  private

  def stop_server_if_running
    @manager.stop if @manager.running?
  rescue Gemkeeper::ServerNotRunningError
    # Already stopped
  end

  def server_responds?(timeout: 5)
    deadline = Time.now + timeout
    uri = URI(@config.geminabox_url)

    while Time.now < deadline
      begin
        response = Net::HTTP.get_response(uri)
        return true if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError
        # Not ready yet
      end
      sleep 0.3
    end

    false
  end
end
