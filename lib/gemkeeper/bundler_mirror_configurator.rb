# frozen_string_literal: true

module Gemkeeper
  # Configures Bundler mirror settings so private gem registries proxy through the local Gemkeeper server.
  class BundlerMirrorConfigurator
    def initialize(candidates, port:, global:)
      @remotes = candidates.filter_map { |c| c[:remote] if c[:source_type] == :private_gem }.uniq
      @local_url = "http://localhost:#{port}"
      @scope = global ? "--global" : "--local"
    end

    def configure(output: $stdout)
      return if @remotes.empty?

      output.puts ""
      @remotes.each { |remote| configure_mirror(remote, output) }
    end

    private

    def configure_mirror(remote, output)
      if system("bundle", "config", "set", @scope, "mirror.#{remote}", @local_url, out: File::NULL)
        output.puts "Configured: bundle config set #{@scope} mirror.#{remote} #{@local_url}"
      else
        warn "Warning: failed to configure bundler mirror for #{remote}"
        warn "  Run manually: bundle config set #{@scope} mirror.#{remote} #{@local_url}"
      end
    end
  end
end
