require "test_helper"

class AccessTest < TourpaqAuthTestCase
  def access_calls(provider) = provider.requests.count { _1[:path].start_with?("/api/v1/access/") }

  def test_an_active_user_with_role_and_sessions_valid_after
    with_auth do |provider|
      valid_after = Time.at(TourpaqAuth.now.to_i - 60).utc
      sub = provider.add_user(email: "x@tourpaq.com", name: "X", role: "responder", sessions_valid_after: valid_after)
      result = TourpaqAuth::Access.check(sub)
      assert result.active?
      refute result.stale?
      assert_equal [ sub, "responder", "x@tourpaq.com", "X" ], [ result.sub, result.role, result.email, result.name ]
      assert_equal valid_after, result.sessions_valid_after
      assert_kind_of Time, result.checked_at
      assert result.session_revoked?(valid_after - 1)
      refute result.session_revoked?(valid_after)
    end
  end

  def test_the_client_authenticates_with_basic
    with_auth(client_id: "irm-web", client_secret: "s3cret") do |provider|
      TourpaqAuth::Access.check(provider.add_user(email: "x@tourpaq.com"))
      assert_equal "Basic #{['irm-web:s3cret'].pack('m0')}", provider.requests.last[:headers]["Authorization"]
    end
  end

  def test_unknown_or_removed_users_are_not_active_and_have_no_role
    with_auth do |provider|
      refute TourpaqAuth::Access.check("nobody").active?
      sub = provider.add_user(email: "x@tourpaq.com", role: "admin")
      provider.remove_access(sub)
      result = TourpaqAuth::Access.check(sub)
      refute result.active?
      assert_nil result.role
    end
  end

  def test_answers_are_cached_for_max_age
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com", role: "viewer")
      TourpaqAuth::Access.check(sub)
      provider.set_role(sub, "admin")
      travel 299
      assert_equal "viewer", TourpaqAuth::Access.check(sub).role
      assert_equal 1, access_calls(provider)
      travel 2
      assert_equal "admin", TourpaqAuth::Access.check(sub).role
      assert_equal 2, access_calls(provider)
    end
  end

  def test_a_shorter_max_age_from_the_auth_app_wins_and_force_skips_the_cache
    with_auth do |provider|
      provider.access_max_age = 60
      sub = provider.add_user(email: "x@tourpaq.com")
      TourpaqAuth::Access.check(sub)
      travel 61
      TourpaqAuth::Access.check(sub)
      assert_equal 2, access_calls(provider)
      TourpaqAuth::Access.check(sub, force: true)
      assert_equal 3, access_calls(provider)
    end
  end

  def test_the_last_known_answer_stands_in_during_an_outage_for_the_grace_period
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com", role: "responder")
      TourpaqAuth::Access.check(sub)
      provider.reachable = false

      travel 3600
      result = TourpaqAuth::Access.check(sub)
      assert result.active?
      assert result.stale?
      assert_equal "responder", result.role

      travel 23 * 3600 + 1 # 24 hours and a second after the last answer
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Access.check(sub) }
    end
  end

  def test_the_grace_period_is_configurable
    with_auth(env: { "LOGIN_GRACE_HOURS" => "1" }) do |provider|
      sub = provider.add_user(email: "x@tourpaq.com")
      TourpaqAuth::Access.check(sub)
      provider.reachable = false
      travel 3599
      assert TourpaqAuth::Access.check(sub).stale?
      travel 2
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Access.check(sub) }
    end
  end

  def test_server_errors_count_as_an_outage
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com")
      TourpaqAuth::Access.check(sub)
      provider.access_status = 503
      travel 301
      assert TourpaqAuth::Access.check(sub).stale?
    end
  end

  def test_without_a_last_known_answer_an_outage_raises
    with_auth do |provider|
      provider.reachable = false
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Access.check("someone") }
    end
  end

  def test_wrong_client_credentials_are_an_error_not_an_outage
    with_auth(env: { "LOGIN_CLIENT_SECRET" => "wrong" }) do
      error = assert_raises(TourpaqAuth::Error) { TourpaqAuth::Access.check("someone") }
      refute_kind_of TourpaqAuth::Unavailable, error
      assert_match "401", error.message
    end
  end

  def test_not_configured_raises
    with_auth(env: { "LOGIN_ISSUER" => nil }) do
      assert_raises(TourpaqAuth::NotConfigured) { TourpaqAuth::Access.check("someone") }
    end
  end

  def test_the_cache_is_pluggable
    with_auth do |provider|
      cache = RecordingCache.new
      TourpaqAuth.config.cache = cache
      sub = provider.add_user(email: "x@tourpaq.com")
      TourpaqAuth::Access.check(sub)
      write = cache.writes.last
      assert write[:key].start_with?("tourpaq_auth:access:test-web:")
      assert_equal 24 * 3600, write[:expires_in], "kept for the grace period"
      assert_equal 300, write[:value]["fresh_until"] - write[:value]["fetched_at"]
    end
  end

  def test_forget_drops_the_cached_answer
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com")
      TourpaqAuth::Access.check(sub)
      TourpaqAuth::Access.forget(sub)
      TourpaqAuth::Access.check(sub)
      assert_equal 2, access_calls(provider)
    end
  end

  def test_members_with_etag
    with_auth do |provider|
      a = provider.add_user(email: "a@tourpaq.com", role: "viewer")
      b = provider.add_user(email: "b@tourpaq.com", role: "admin")
      c = provider.add_user(email: "c@tourpaq.com", role: "admin")
      provider.remove_access(c)

      first = TourpaqAuth::Access.members
      refute first.not_modified?
      assert_equal [ [ a, "viewer" ], [ b, "admin" ] ], first.members.map { [ _1.sub, _1.role ] }
      assert_equal "a@tourpaq.com", first.members.first.email
      refute_nil first.etag

      again = TourpaqAuth::Access.members(etag: first.etag)
      assert again.not_modified?
      assert_nil again.members
      assert_equal first.etag, provider.requests.last[:headers]["If-None-Match"]

      provider.disable_user(a)
      changed = TourpaqAuth::Access.members(etag: first.etag)
      refute changed.not_modified?
      assert_equal [ b ], changed.members.map(&:sub)
    end
  end

  def test_sync_members_yields_only_on_change_and_keeps_the_etag_after_success
    with_auth do |provider|
      provider.add_user(email: "a@tourpaq.com")
      seen = []
      TourpaqAuth::Access.sync_members { seen << _1.map(&:email) }
      TourpaqAuth::Access.sync_members { seen << _1.map(&:email) }
      assert_equal [ [ "a@tourpaq.com" ] ], seen

      provider.add_user(email: "b@tourpaq.com")
      assert_raises(RuntimeError) { TourpaqAuth::Access.sync_members { raise "database down" } }
      TourpaqAuth::Access.sync_members { seen << _1.map(&:email) }
      assert_equal [ "a@tourpaq.com", "b@tourpaq.com" ], seen.last, "a failed sync is retried in full"
    end
  end

  def test_members_outage_raises_unavailable
    with_auth do |provider|
      provider.members_status = 502
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Access.members }
    end
  end
end
