# frozen_string_literal: true

require "integration_helper"
require "net/http"
require "rubygems/package"

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
    assert_equal @config.server_url, status[:url]
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
    assert_match(/CompactIndexServer/, content)
    assert_match(/gems_path:/, content)
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

  # Regression: a gem built locally but absent from a freshly started server must
  # be re-uploaded by `sync` (not skipped on a stale local-cache check) and then
  # served. This is the original 404 bug. (spec FR-1.1, FR-1.3, FR-2.1)
  def test_sync_repopulates_empty_server_from_existing_artifact
    build_test_gem("reg-gem", "1.0.0", @config.gems_path)
    File.write(@config_path, {
      "port" => @port,
      "gems_path" => @config.gems_path,
      "repos_path" => File.join(@temp_dir, "repos"),
      "gems" => [{ "name" => "reg-gem", "version" => "1.0.0" }]
    }.to_yaml)

    @manager.start
    uploader = Gemkeeper::GemUploader.new(@config.server_url)
    refute uploader.serves?("reg-gem", "1.0.0"), "fresh server should not yet serve the gem"

    run_gemkeeper("sync", "reg-gem", "--config", @config_path)

    assert uploader.serves?("reg-gem", "1.0.0"), "sync should have re-uploaded the gem"
    assert_equal 200, gem_file_status("reg-gem-1.0.0.gem"), "server should serve the re-uploaded gem"
  end

  def test_sync_skips_when_server_already_serves
    build_test_gem("skip-gem", "1.0.0", @config.gems_path)
    File.write(@config_path, {
      "port" => @port,
      "gems_path" => @config.gems_path,
      "repos_path" => File.join(@temp_dir, "repos"),
      "gems" => [{ "name" => "skip-gem", "version" => "1.0.0" }]
    }.to_yaml)
    @manager.start

    run_gemkeeper("sync", "skip-gem", "--config", @config_path)          # first run uploads
    result = run_gemkeeper("sync", "skip-gem", "--config", @config_path) # second run skips

    assert_match(/1 skipped/, result[:stdout])
  end

  private

  def gem_file_status(filename)
    Net::HTTP.get_response(URI("#{@config.server_url}/gems/#{filename}")).code.to_i
  end

  def build_test_gem(name, version, dest_dir)
    spec = Gem::Specification.new do |s|
      s.name     = name
      s.version  = version
      s.summary  = "Test gem"
      s.authors  = ["Test"]
      s.files    = []
    end
    FileUtils.mkdir_p(dest_dir)
    Dir.mktmpdir do |build_dir|
      Dir.chdir(build_dir) { Gem::Package.build(spec) }
      FileUtils.mv(File.join(build_dir, "#{name}-#{version}.gem"), File.join(dest_dir, "#{name}-#{version}.gem"))
    end
  end

  def stop_server_if_running
    @manager.stop if @manager.running?
  rescue Gemkeeper::ServerNotRunningError
    # Already stopped
  end

  def server_responds?(timeout: 5)
    deadline = Time.now + timeout
    uri = URI(@config.server_url)

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
