# frozen_string_literal: true

module Gemkeeper
  module Output
    COLORS = {
      green: "\e[32m",
      yellow: "\e[33m",
      red: "\e[31m",
      dim: "\e[2m",
      reset: "\e[0m"
    }.freeze

    module_function

    def colorize(text, color)
      return text unless $stdout.tty?

      "#{COLORS[color]}#{text}#{COLORS[:reset]}"
    end

    def step(msg)    = puts colorize("  #{msg}", :dim)
    def success(msg) = puts colorize(msg, :green)
    def skip(msg)    = puts colorize(msg, :yellow)
    def failure(msg) = warn colorize(msg, :red)
  end
end
