# frozen_string_literal: true

require "fileutils"

module Gemkeeper
  # Owns the rackup/puma lifecycle so CLI commands delegate process management here.
  class ServerManager
    attr_reader :config

    def initialize(config)
      @config = config
    end

    def start
      ensure_not_running!
      RackupProcess.new(config).start
    end

    def start_foreground
      ensure_not_running!
      RackupProcess.new(config).start_foreground
    end

    def stop
      raise ServerNotRunningError, "Server is not running" unless running?

      pid = read_pid
      Process.kill("TERM", pid)
      wait_for_process_exit(pid)
      cleanup_pid_file
      true
    rescue Errno::ESRCH
      cleanup_pid_file
      true
    end

    def status
      if running?
        { running: true, pid: read_pid, url: config.geminabox_url }
      else
        { running: false }
      end
    end

    def running?
      return false unless File.exist?(config.pid_file)

      pid = read_pid
      return false unless pid

      process_alive?(pid)
    end

    private

    def ensure_not_running!
      raise ServerAlreadyRunningError, "Server is already running (PID: #{read_pid})" if running?
    end

    def wait_for_process_exit(pid)
      10.times do
        return unless process_alive?(pid)

        sleep 0.5
      end
      Process.kill("KILL", pid) if process_alive?(pid)
    end

    def read_pid
      pid_file = config.pid_file
      return nil unless File.exist?(pid_file)

      pid = File.read(pid_file).strip.to_i
      pid.positive? ? pid : nil
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def cleanup_pid_file
      FileUtils.rm_f(config.pid_file)
    end
  end
end
