# frozen_string_literal: true

module Gemkeeper
  module CLI
    # Shared path coercion for commands that accept a Gemfile.lock argument.
    # Accepts nil (find nearest), a directory, a Gemfile path, or an explicit path.
    module LockfileResolution
      private

      def resolve_source_path(path)
        resolved = coerce_source_path(path)
        File.exist?(resolved) ? resolved : missing_source!(resolved)
      end

      def coerce_source_path(path)
        return LockfileParser.find || no_lockfile! if path.nil?
        return File.join(path, "Gemfile.lock") if File.directory?(path)
        return File.join(File.dirname(path), "Gemfile.lock") if File.basename(path) == "Gemfile"

        path
      end

      def no_lockfile!
        warn "Error: no Gemfile.lock found in #{Dir.pwd} or any parent directory"
        exit 1
      end

      def missing_source!(path)
        warn "Error: file not found — #{path}"
        exit 1
      end
    end
  end
end
