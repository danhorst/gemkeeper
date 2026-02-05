# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "test_gem"
  spec.version = "0.1.0"
  spec.authors = ["Test Author"]
  spec.email = ["test@example.com"]
  spec.summary = "A test gem for integration testing"
  spec.homepage = "https://example.com/test_gem"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*"]
  spec.require_paths = ["lib"]
end
