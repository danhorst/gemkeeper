# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TestGemUploader < Minitest::Test
  CLOSED_PORT_URL = "http://localhost:39999"

  def test_upload_raises_server_not_reachable_on_connection_failure
    Dir.mktmpdir do |tmpdir|
      gem_path = File.join(tmpdir, "my-gem-1.0.0.gem")
      File.write(gem_path, "fake gem content")

      uploader = Gemkeeper::GemUploader.new(CLOSED_PORT_URL)

      assert_raises(Gemkeeper::ServerNotReachableError) do
        uploader.upload(gem_path)
      end
    end
  end

  def test_upload_error_message_includes_url_and_hint
    Dir.mktmpdir do |tmpdir|
      gem_path = File.join(tmpdir, "my-gem-1.0.0.gem")
      File.write(gem_path, "fake gem content")

      uploader = Gemkeeper::GemUploader.new(CLOSED_PORT_URL)

      error = assert_raises(Gemkeeper::ServerNotReachableError) do
        uploader.upload(gem_path)
      end

      assert_match(/#{Regexp.escape(CLOSED_PORT_URL)}/o, error.message)
      assert_match(/gemkeeper server start/, error.message)
    end
  end

  def test_reachable_returns_false_when_server_not_running
    uploader = Gemkeeper::GemUploader.new(CLOSED_PORT_URL)
    refute uploader.reachable?
  end

  def test_serves_raises_server_not_reachable_on_connection_failure
    uploader = Gemkeeper::GemUploader.new(CLOSED_PORT_URL)

    error = assert_raises(Gemkeeper::ServerNotReachableError) do
      uploader.serves?("mimir", "1.0.5")
    end

    assert_match(/gemkeeper server start/, error.message)
  end
end
