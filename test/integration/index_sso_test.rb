require "test_helper"

# The index host signs in through the app's own OIDC provider as the internal client "index", like the admin
# host (SPECS.md §24.1): its own host-only session, 8 h idle / 7 days from the Entra sign-in, the user re-checked.
class IndexSsoTest < ActionDispatch::IntegrationTest
  # Index host → auth /oauth/authorize. Returns the authorize query the index host sent.
  def start_index_sign_in(path = "/")
    on_index_host!
    get path
    location = URI(response.location)
    assert_equal [ auth_host, "/oauth/authorize" ], [ location.host, location.path ]
    URI.decode_www_form(location.query).to_h
  end

  test "round trip: PKCE, state and nonce, the code exchanged in-process, a host-only index session" do
    sign_in_as users(:alice)
    query = start_index_sign_in("/profile")
    assert_equal [ "code", "index", AuthHosts.index_callback_url, "openid email profile", "S256" ],
                 query.values_at("response_type", "client_id", "redirect_uri", "scope", "code_challenge_method")
    assert query["state"].present? && query["nonce"].present? && query["code_challenge"].present?
    assert_nil query["max_age"], "no fresh sign-in needed for the index"

    follow_redirect! # auth host: a code for the index host
    assert response.location.start_with?("#{AuthHosts.index_callback_url}?")
    follow_redirect! # index host /sso/callback
    assert_redirected_to "/profile"
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    assert_match(/index_session=/, set_cookie)
    assert_match(/httponly/i, set_cookie)
    assert_match(/samesite=lax/i, set_cookie)
    assert_no_match(/index_session=[^\n]*domain=/i, set_cookie)
    follow_redirect!
    assert_response :success
    assert_select "h1", "Alice Popescu"

    index = Session.index_host.last
    home = Session.home.last
    assert_equal [ users(:alice), "index" ], [ index.user, index.kind ]
    assert_in_delta home.entra_authenticated_at.to_i, index.entra_authenticated_at.to_i, 1, "7 days count from the Entra sign-in"
    assert AuthorizationCode.last.used?
    assert_equal Client.index_client, AuthorizationCode.last.client
    event = AuditEvent.where(action: "auth.login").last
    assert_equal [ users(:alice), "index" ], [ event.subject, event.data["kind"] ]
  end

  test "without an auth session the index host's sign-in goes through Entra first, then on" do
    query = start_index_sign_in
    follow_redirect!
    assert_redirected_to "/sign_in"
    sign_in_with_entra(email: users(:alice).email, name: users(:alice).name, oid: users(:alice).entra_oid, tid: users(:alice).entra_tid)
    follow_redirect! # back to /oauth/authorize
    assert response.location.start_with?(AuthHosts.index_callback_url)
    assert_equal query["state"], URI.decode_www_form(URI(response.location).query).to_h["state"]
    follow_redirect!
    assert_redirected_to "/"
  end

  test "the callback checks the state" do
    sign_in_as users(:alice)
    start_index_sign_in
    follow_redirect!
    code = URI.decode_www_form(URI(response.location).query).to_h["code"]
    get "#{AuthHosts.index_callback_url}?#{{ code: code, state: 'forged' }.to_query}"
    assert_response :forbidden
    assert_select "h1", "Sign-in failed"
    event = AuditEvent.last
    assert_equal [ "auth.login_refused", "index", "state" ], [ event.action, event.data["kind"], event.data["reason"] ]
    assert_not Session.index_host.exists?
  end

  test "a sign-in older than 10 minutes is refused" do
    sign_in_as users(:alice)
    start_index_sign_in
    follow_redirect!
    callback = response.location
    travel 11.minutes
    get callback
    assert_response :forbidden
    assert_equal "timeout", AuditEvent.last.data["reason"]
  end

  test "a code is good once, for the index client and its exact redirect URI, over HTTP never" do
    sign_in_as users(:alice)
    start_index_sign_in
    follow_redirect!
    callback = response.location
    code = URI.decode_www_form(URI(callback).query).to_h["code"]
    on_auth_host!
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: AuthHosts.index_callback_url, client_id: "index" }
    assert_response :unauthorized, "the internal client is refused over HTTP"
    get callback
    assert_redirected_to "/"
    reset!
    get callback
    assert_response :forbidden, "another browser has no state for it"
  end

  test "a disabled user is refused at authorize and their index session ends at the next request" do
    sign_in_index users(:alice)
    assert_response :success
    users(:alice).disable!(actor: users(:mwi))
    get "/"
    assert_equal "/oauth/authorize", URI(response.location).path
    assert_equal "disabled", Session.index_host.last.end_reason
  end

  test "a user disabled behind the session's back (no domain method) is still out at the next request" do
    sign_in_index users(:alice)
    users(:alice).update_columns(disabled_at: Time.current)
    get "/"
    assert_equal "/oauth/authorize", URI(response.location).path
    assert_equal [ "disabled", "session.expired" ], [ Session.index_host.last.end_reason, AuditEvent.last.action ]
  end

  test "sign out everywhere ends the index session" do
    sign_in_index users(:alice)
    users(:alice).sign_out_everywhere!(actor: users(:mwi))
    get "/"
    assert_equal "/oauth/authorize", URI(response.location).path
  end

  test "8 hours idle ends the index session" do
    sign_in_index users(:alice)
    travel 8.hours + 1.minute
    get "/"
    assert_equal "/oauth/authorize", URI(response.location).path
    assert_equal "idle", Session.index_host.last.end_reason
  end

  test "7 days after the Entra sign-in the index session ends, however active" do
    sign_in_index users(:alice)
    23.times do
      travel 7.hours
      get "/"
      assert_response :success
    end
    travel 7.hours + 1.minute
    get "/"
    assert_equal "/oauth/authorize", URI(response.location).path
    assert_equal "expired", Session.index_host.last.expiry_reason # the cookie itself expires then too
  end

  test "an index session started late in the auth session still ends 7 days after the Entra sign-in" do
    sign_in_as users(:alice)
    6.times { travel 7.hours; get "/" } # the auth session stays alive, 42 hours after the Entra sign-in
    sign_in_index users(:alice), sign_in: false
    17.times { travel 7.hours; get "/"; assert_response :success } # 161 hours
    travel 6.hours + 58.minutes
    get "/"
    assert_response :success
    travel 3.minutes # 7 days and a minute after the Entra sign-in, 5 days after the index sign-in
    get "/"
    assert_equal "/oauth/authorize", URI(response.location).path
    assert_equal "expired", Session.index_host.last.end_reason
  end

  test "the callback's ID token check: issuer APP_URL, audience index, the kept nonce" do
    token = ->(client, nonce) { Oidc::IdToken.issue(user: users(:alice), client: client, nonce: nonce, auth_time: nil) }
    claims = Oidc::IdToken.verify(token.(Client.index_client, "n"), audience: "index", nonce: "n")
    assert_equal [ "http://auth.example.com", "index", users(:alice).sub ], claims.values_at("iss", "aud", "sub")
    assert_raises(Oidc::InvalidToken) { Oidc::IdToken.verify(token.(Client.admin_client, "n"), audience: "index", nonce: "n") }
    assert_raises(Oidc::InvalidToken) { Oidc::IdToken.verify(token.(Client.index_client, "n"), audience: "index", nonce: "other") }
  end

  test "an error from the authorization server shows Sign-in failed" do
    sign_in_as users(:alice)
    query = start_index_sign_in
    get "/sso/callback?#{{ error: 'access_denied', state: query['state'] }.to_query}"
    assert_response :forbidden
    assert_equal "access_denied", AuditEvent.last.data["reason"]
  end

  test "sign out: the index session ends, then the auth session through /oauth/logout, back at /signed_out" do
    sign_in_index users(:alice)
    index = Session.index_host.last
    home = Session.home.last
    delete "/session"
    location = URI(response.location)
    assert_equal [ auth_host, "/oauth/logout" ], [ location.host, location.path ]
    query = URI.decode_www_form(location.query).to_h
    assert_equal [ "index", "http://index.example.com/signed_out" ], query.values_at("client_id", "post_logout_redirect_uri")
    hint = Oidc::IdToken.verify_hint(query["id_token_hint"])
    assert_equal %w[aud exp iat iss sub], hint.keys.sort, "no email or name in a URL"
    assert_equal [ users(:alice).sub, "index" ], hint.values_at("sub", "aud")
    assert_not index.reload.active?

    follow_redirect! # the auth host: the hint names alice, who is signed in here, so no confirmation
    assert_redirected_to "http://index.example.com/signed_out"
    assert_equal "signed_out", home.reload.end_reason
    assert_equal %w[auth.logout auth.logout], AuditEvent.order(:id).last(2).map(&:action)
    follow_redirect!
    assert_response :success
    assert_select "h1", "You are signed out"

    get "/"
    follow_redirect! # /oauth/authorize: no auth session any more
    assert_redirected_to "/sign_in"
  end

  test "sign out without an index session or an auth session lands on the signed-out page" do
    on_index_host!
    delete "/session"
    follow_redirect!
    assert_redirected_to "http://index.example.com/signed_out", "without a hint and without an auth session: straight back"
    follow_redirect!
    assert_response :success
  end

  test "the internal client index: any active user may authorize; it has no app and no role claim" do
    client = Client.index_client
    assert [ client.internal?, client.app ].then { _1 && _2.nil? }
    assert Oidc::Access.allowed?(users(:bob), client), "a pending user too (the index host sends them to waiting)"
    assert_not Oidc::Access.allowed?(users(:dave_disabled), client)
    assert_not Oidc::Access.allowed?(users(:alice), Client.admin_client)
    assert_equal [ AuthHosts.index_callback_url ], client.redirect_uris
    assert_equal [ "http://index.example.com/signed_out" ], client.post_logout_redirect_uris
    claims = Oidc::IdToken.user_claims(users(:alice), client)
    assert_nil claims["irm_role"]
  end
end
