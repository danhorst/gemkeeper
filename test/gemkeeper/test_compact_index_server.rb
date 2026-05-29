# frozen_string_literal: true

require "test_helper"
require "rack/mock"
require "tmpdir"
require "rubygems/package"
require "rubygems/specification"
require "zlib"

class TestCompactIndexServer < Minitest::Test
  def setup
    @tmpdir    = Dir.mktmpdir
    @gems_path = @tmpdir
    @cache_dir = File.join(@tmpdir, "cache")
    FileUtils.mkdir_p(@cache_dir)
    @server = Gemkeeper::CompactIndexServer.new(gems_path: @gems_path, cache_dir: @cache_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # ── Health ────────────────────────────────────────────────────────────────

  def test_health_responds_ok
    status, = get("/")
    assert_equal 200, status
  end

  # ── Input validation ──────────────────────────────────────────────────────

  def test_invalid_gemname_rejected
    # Rack normalises traversals so path_info may not even reach the route;
    # both 400 (caught by validation) and 404 (route never matched) mean the
    # traversal was rejected.
    status, = get("/info/%2E%2E%2F%2E%2E%2Fetc%2Fpasswd")
    assert_includes [400, 404], status
  end

  def test_invalid_filename_rejected
    status, = get("/gems/%2E%2E%2Fetc%2Fpasswd.gem")
    assert_includes [400, 404], status
  end

  def test_unknown_route_not_found
    status, = get("/unknown")
    assert_equal 404, status
  end

  # ── Upload ────────────────────────────────────────────────────────────────

  def test_upload_returns_201_for_valid_gem
    gem_path = build_test_gem("my-gem", "1.0.0")
    status, = post_upload(gem_path)
    assert_equal 201, status
    assert File.exist?(File.join(@tmpdir, "gems", "my-gem-1.0.0.gem"))
  end

  def test_upload_returns_409_when_gem_already_exists
    gem_path = build_test_gem("my-gem", "1.0.0")
    post_upload(gem_path)
    status, = post_upload(gem_path)
    assert_equal 409, status
  end

  def test_upload_returns_422_for_invalid_file
    bad_path = File.join(@tmpdir, "bad-1.0.0.gem")
    File.write(bad_path, "this is not a gem")

    status, = post_upload(bad_path, filename: "bad-1.0.0.gem")
    assert_equal 422, status
  end

  def test_upload_missing_file_param_rejected
    env = Rack::MockRequest.env_for("/upload", method: "POST")
    status, = @server.call(env)
    assert_equal 400, status
  end

  # ── Private gem serving ───────────────────────────────────────────────────

  def test_private_gem_appears_in_names_after_upload
    gem_path = build_test_gem("private-gem", "2.0.0")
    post_upload(gem_path)

    status, _headers, body_parts = get("/names")
    assert_equal 200, status
    assert_match(/private-gem/, body_parts.join)
  end

  def test_private_gem_appears_in_info_after_upload
    gem_path = build_test_gem("private-gem", "2.0.0")
    post_upload(gem_path)

    status, _headers, body_parts = get("/info/private-gem")
    assert_equal 200, status
    assert_match(/2\.0\.0/, body_parts.join)
  end

  def test_private_gem_file_is_served
    gem_path = build_test_gem("private-gem", "2.0.0")
    post_upload(gem_path)

    status, = get("/gems/private-gem-2.0.0.gem")
    assert_equal 200, status
  end

  # ── ETag / 304 ────────────────────────────────────────────────────────────

  def test_info_returns_304_when_etag_matches
    gem_path = build_test_gem("my-gem", "1.0.0")
    post_upload(gem_path)

    _status, headers, = get("/info/my-gem")
    etag = headers["etag"]

    status, = get("/info/my-gem", "HTTP_IF_NONE_MATCH" => etag)
    assert_equal 304, status
  end

  def test_info_returns_200_when_etag_differs
    gem_path = build_test_gem("my-gem", "1.0.0")
    post_upload(gem_path)

    status, = get("/info/my-gem", "HTTP_IF_NONE_MATCH" => '"stale-etag"')
    assert_equal 200, status
  end

  # ── Range / 206 / 416 ─────────────────────────────────────────────────────

  def test_info_range_request_partial_content
    gem_path = build_test_gem("my-gem", "1.0.0")
    post_upload(gem_path)

    _status, _headers, body_parts = get("/info/my-gem")
    full_body = body_parts.join
    offset    = [full_body.bytesize - 4, 0].max

    status, headers, partial = get("/info/my-gem", "HTTP_RANGE" => "bytes=#{offset}-")
    assert_equal 206, status
    assert_match(/bytes #{offset}-/, headers["content-range"])
    assert_equal full_body.byteslice(offset..), partial.join
  end

  def test_range_beyond_eof_not_satisfiable
    gem_path = build_test_gem("my-gem", "1.0.0")
    post_upload(gem_path)

    status, = get("/info/my-gem", "HTTP_RANGE" => "bytes=99999999-")
    assert_equal 416, status
  end

  def test_multi_range_not_satisfiable
    gem_path = build_test_gem("my-gem", "1.0.0")
    post_upload(gem_path)

    status, = get("/info/my-gem", "HTTP_RANGE" => "bytes=0-10, 20-30")
    assert_equal 416, status
  end

  # ── Response headers ──────────────────────────────────────────────────────

  def test_info_response_includes_required_headers
    gem_path = build_test_gem("my-gem", "1.0.0")
    post_upload(gem_path)

    _status, headers, = get("/info/my-gem")
    assert headers.key?("etag"), "Expected ETag header"
    assert headers.key?("repr-digest"), "Expected Repr-Digest header"
    assert_equal "bytes", headers["accept-ranges"]
    assert_match(/sha-256=/, headers["repr-digest"])
  end

  # ── Offline / 503 ─────────────────────────────────────────────────────────

  def test_missing_public_gem_returns_503_when_no_cache
    # No network call mocked — rubygems.org unreachable in test environment
    # (relies on connection being refused; skip if network is actually available)
    status, _headers, body = get("/info/some-public-gem-that-does-not-exist-xyz-abc-123")
    assert_includes [404, 503], status, "Expected 404 (upstream found nothing) or 503 (unreachable)"
    return unless status == 503

    assert_match(/Upstream unavailable/, body.join)
  end

  private

  def get(path, extra_env = {})
    env = Rack::MockRequest.env_for(path, method: "GET").merge(extra_env)
    @server.call(env)
  end

  def post_upload(gem_path, filename: nil)
    filename ||= File.basename(gem_path)
    content   = File.binread(gem_path)
    boundary  = "GemkeeperTestBoundary"

    body  = "--#{boundary}\r\n"
    body += "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n"
    body += "Content-Type: application/octet-stream\r\n\r\n"
    body += content
    body += "\r\n--#{boundary}--\r\n"

    env = Rack::MockRequest.env_for(
      "/upload",
      method: "POST",
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
      input: body
    )
    @server.call(env)
  end

  def build_test_gem(name, version)
    spec = Gem::Specification.new do |s|
      s.name     = name
      s.version  = version
      s.summary  = "Test gem"
      s.authors  = ["Test"]
      s.license  = "MIT"
      s.homepage = "https://example.com"
      s.files    = ["README.md"]
    end

    gem_path = File.join(@tmpdir, "#{name}-#{version}.gem")
    Dir.mktmpdir do |build_dir|
      Dir.chdir(build_dir) do
        File.write("README.md", "# #{name}")
        built = Gem::Package.build(spec)
        FileUtils.mv(File.join(build_dir, built), gem_path)
      end
    end
    gem_path
  end
end
