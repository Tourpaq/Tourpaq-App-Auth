require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "start! stores only the digest and finds the session by the plain token and kind" do
    session, plain = Session.start!(user: users(:alice), kind: "home", ip_address: "10.0.0.1", user_agent: "Firefox/1")
    assert_equal 43, plain.length
    assert_equal Digest::SHA256.hexdigest(plain), session.token_digest
    assert_not_includes Session.pluck(:token_digest), plain
    assert_equal session, Session.find_by_plain(plain, kind: "home")
    assert_nil Session.find_by_plain(plain, kind: "admin")
    assert_nil Session.find_by_plain("", kind: "home")
    session.end!("signed_out")
    assert_nil Session.find_by_plain(plain, kind: "home")
  end

  test "auth (home) sessions: 8 hours idle, 7 days since the Entra sign-in" do
    session, = Session.start!(user: users(:alice))
    travel 7.hours + 59.minutes
    assert_not session.expired?
    travel 2.minutes
    assert_equal "idle", session.expiry_reason

    session.update_columns(last_seen_at: Time.current)
    assert_not session.expired?
    session.update_columns(entra_authenticated_at: 7.days.ago - 1.minute)
    assert_equal "expired", session.expiry_reason
  end

  test "index sessions: the auth session's limits, kept apart by kind" do
    session, plain = Session.start!(user: users(:alice), kind: "index", entra_authenticated_at: 6.days.ago)
    assert_equal [ session ], Session.index_host.to_a
    assert_nil Session.find_by_plain(plain, kind: "home")
    assert_equal session, Session.find_by_plain(plain, kind: "index")
    assert_equal [ "index", "auth", "admin" ], %w[index home admin].map { Session.new(kind: _1).host_label }
    travel 7.hours + 59.minutes
    assert_not session.expired?
    travel 2.minutes
    assert_equal "idle", session.expiry_reason
    session.update_columns(last_seen_at: Time.current)
    travel 1.day # 7 days and a bit since the Entra sign-in
    session.update_columns(last_seen_at: Time.current)
    assert_equal "expired", session.expiry_reason
  end

  test "admin sessions: 2 hours idle, 12 hours since the Entra sign-in" do
    session, = Session.start!(user: users(:mwi), kind: "admin", entra_authenticated_at: 9.hours.ago)
    travel 1.hour + 59.minutes
    assert_not session.expired?
    travel 2.minutes
    assert_equal "idle", session.expiry_reason
    session.update_columns(last_seen_at: Time.current)
    assert_not session.expired?
    travel 1.hour
    assert_equal "expired", session.expiry_reason # 12 hours and a minute since the Entra sign-in
  end

  test "a session started before sessions_valid_after is expired" do
    session, = Session.start!(user: users(:alice))
    travel 1.minute
    users(:alice).update!(sessions_valid_after: Time.current)
    assert_equal "signed_out_everywhere", session.reload.expiry_reason
  end

  test "touch_seen! writes at most once a minute" do
    session, = Session.start!(user: users(:alice))
    seen = session.last_seen_at
    travel 30.seconds
    session.touch_seen!
    assert_equal seen, session.reload.last_seen_at
    travel 31.seconds
    session.touch_seen!(ip_address: "10.1.1.1")
    assert_operator session.reload.last_seen_at, :>, seen
    assert_equal "10.1.1.1", session.ip_address
  end

  test "browser label" do
    session = Session.new(user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 Version/17.5 Safari/605.1.15")
    assert_equal "Safari on macOS", session.browser_label
    session.user_agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) Version/17.5 Mobile Safari/604.1"
    assert_equal "Safari on iOS", session.browser_label
  end
end
