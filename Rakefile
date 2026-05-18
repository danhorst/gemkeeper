# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create

require "rubocop/rake_task"

RuboCop::RakeTask.new

require "rubycritic/rake_task"

code_paths = FileList["lib/**/*.rb"]

RubyCritic::RakeTask.new do |task|
  task.paths = code_paths
end

RubyCritic::RakeTask.new("rubycritic:headless", "Run RubyCritic (headless)") do |task|
  task.paths = code_paths
  task.options = "--no-browser --format json"
end

RubyCritic::RakeTask.new("rubycritic:ci", "Run RubyCritic (CI configuration)") do |task|
  task.paths = code_paths
  task.options = "--mode-ci --no-browser --format json"
end

task default: %i[rubocop test rubycritic]
