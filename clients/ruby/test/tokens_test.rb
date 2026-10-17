require "test_helper"

class TokensTest < TourpaqAuthTestCase
  def test_an_active_personal_token
    with_auth(client_id: "irm-web") do |provider|
      sub = provider.add_user(email: "x@tourpaq.com", name: "X", role: "responder")
      token = provider.issue_token(sub: sub, scope: "read_write", name: "Claude Code")
      assert token.start_with?("tpa_irm_")

      result = TourpaqAuth::Tokens.introspect(token)
      assert result.active?
      assert result.read_write?
      assert result.read?
      assert_equal [ "personal", sub, "x@tourpaq.com", "X", "read_write", "responder", "irm", "irm-web", "Claude Code" ],
                   [ result.token_type, result.sub, result.email, result.name, result.scope, result.role, result.app,
                     result.client_id, result.token_name ]
      assert_kind_of Time, result.exp
      assert_equal "Basic #{['irm-web:test-client-secret'].pack('m0')}", provider.requests.last[:headers]["Authorization"]
    end
  end

  def test_a_read_token_cannot_write
    with_auth do |provider|
      token = provider.issue_token(sub: provider.add_user(email: "x@tourpaq.com"), scope: "read")
      result = TourpaqAuth::Tokens.introspect(token)
      assert result.read?
      refute result.read_write?
    end
  end

  def test_extension_tokens
    with_auth do |provider|
      token = provider.issue_token(sub: provider.add_user(email: "x@tourpaq.com"), token_type: "extension", scope: "read_write")
      assert token.start_with?("tpx_test_")
      assert_equal "extension", TourpaqAuth::Tokens.introspect(token).token_type
    end
  end

  def test_unknown_foreign_revoked_and_expired_tokens_are_inactive
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com")
      foreign = provider.issue_token(sub: sub, app: "kpi")
      expired = provider.issue_token(sub: sub, expires_in: -1)
      revoked = provider.issue_token(sub: sub)
      provider.revoke_token(revoked)
      [ "tpa_test_unknown", foreign, expired, revoked ].each do |token|
        result = TourpaqAuth::Tokens.introspect(token)
        refute result.active?
        assert_nil result.sub
      end
    end
  end

  def test_blank_or_oversized_tokens_are_inactive_without_asking
    with_auth do |provider|
      refute TourpaqAuth::Tokens.introspect(nil).active?
      refute TourpaqAuth::Tokens.introspect("  ").active?
      refute TourpaqAuth::Tokens.introspect("x" * 5000).active?
      assert_equal 0, provider.introspections
    end
  end

  def test_answers_are_cached_for_sixty_seconds
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com")
      token = provider.issue_token(sub: sub)
      assert TourpaqAuth::Tokens.introspect(token).active?
      provider.revoke_token(token)
      travel 59
      assert TourpaqAuth::Tokens.introspect(token).active?, "still cached"
      assert_equal 1, provider.introspections(token)
      travel 2
      refute TourpaqAuth::Tokens.introspect(token).active?
      assert_equal 2, provider.introspections(token)
    end
  end

  def test_inactive_answers_are_cached_too
    with_auth do |provider|
      2.times { TourpaqAuth::Tokens.introspect("tpa_test_nope") }
      assert_equal 1, provider.introspections
    end
  end

  def test_the_cache_is_keyed_by_the_digest_and_never_holds_the_token
    with_auth(client_id: "irm-web") do |provider|
      cache = RecordingCache.new
      TourpaqAuth.config.cache = cache
      token = provider.issue_token(sub: provider.add_user(email: "x@tourpaq.com"))
      TourpaqAuth::Tokens.introspect(token)

      write = cache.writes.last
      assert_equal "tourpaq_auth:introspect:irm-web:#{Digest::SHA256.hexdigest(token)}", write[:key]
      assert_equal 60, write[:expires_in]
      cache.writes.each do |w|
        refute_includes w[:key], token
        refute_includes w[:value].to_s, token
      end
    end
  end

  def test_the_cache_never_outlives_the_token
    with_auth do |provider|
      token = provider.issue_token(sub: provider.add_user(email: "x@tourpaq.com"), expires_in: 20)
      cache = RecordingCache.new
      TourpaqAuth.config.cache = cache
      TourpaqAuth::Tokens.introspect(token)
      assert_operator cache.writes.last[:expires_in], :<=, 20
      travel 21
      refute TourpaqAuth::Tokens.introspect(token).active?
    end
  end

  def test_an_outage_raises_unavailable
    with_auth do |provider|
      provider.reachable = false
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Tokens.introspect("tpa_test_x") }
      provider.reachable = true
      provider.introspect_status = 500
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Tokens.introspect("tpa_test_x") }
    end
  end

  def test_wrong_client_credentials_are_an_error
    with_auth(env: { "LOGIN_CLIENT_SECRET" => "wrong" }) do
      error = assert_raises(TourpaqAuth::Refused) { TourpaqAuth::Tokens.introspect("tpa_test_x") }
      assert_kind_of TourpaqAuth::Error, error
      refute_kind_of TourpaqAuth::Unavailable, error
      assert_equal 401, error.status
    end
  end

  def test_cached_tells_whether_introspect_would_call_the_auth_app
    with_auth do |provider|
      token = provider.issue_token(sub: provider.add_user(email: "x@tourpaq.com"))
      refute TourpaqAuth::Tokens.cached?(token)
      TourpaqAuth::Tokens.introspect(token)
      assert TourpaqAuth::Tokens.cached?(token)
      TourpaqAuth::Tokens.introspect("tpa_test_nope")
      assert TourpaqAuth::Tokens.cached?("tpa_test_nope"), "inactive answers are cached too"
      refute TourpaqAuth::Tokens.cached?("")
      travel 61
      refute TourpaqAuth::Tokens.cached?(token)
    end
  end
end
