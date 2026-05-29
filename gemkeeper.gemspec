# frozen_string_literal: true

require_relative "lib/gemkeeper/version"

Gem::Specification.new do |spec|
  spec.name = "gemkeeper"
  spec.version = Gemkeeper::VERSION
  spec.authors = ["Dan Brubaker Horst"]
  spec.email = ["dan.brubaker.horst@gmail.com"]

  spec.summary = "Manage offline development with private gem dependencies"
  spec.description = "A utility for building and hosting private gems locally and proxying to RubyGems for the rest."
  spec.homepage = "https://github.com/danhorst/gemkeeper"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      f.start_with?(*%w[
                      .env
                      .git
                      .rubocop
                      AGENT
                      CLAUDE
                      CODE
                      Gemfile
                      Makefile
                      Rakefile
                      bin/
                      gemkeeper
                      img/
                      scripts/
                      test/
                    ])
    end
  end

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "compact_index", "~> 0.15"
  spec.add_dependency "dry-cli", "~> 1.0"
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  spec.add_dependency "puma", "~> 7.0"
  spec.add_dependency "rack", "~> 3.0"
  spec.add_dependency "rackup", "~> 2.0"
end
