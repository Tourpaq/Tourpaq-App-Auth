require "test_helper"

# Sign-in with Entra on the auth host (SPECS.md §3, §24), through OmniAuth's test mode.
class EntraSignInFlowTest < ActionDispatch::IntegrationTest
  test "the auth host's root sends a signed-out browser to the sign-in page" do
    get "/"
    assert_redirected_to "/sign_in"
    follow_redirect!
    assert_response :success
    assert_select "form[action='/auth/entra_id'][method=post] button", "Sign in with Microsoft"
  end

  test "an admin signs in, with a host-only session cookie, and goes on to the index host" do
    sign_in_as users(:mwi)
    assert_redirected_to "/"
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    assert_match(/home_session=/, set_cookie)
    assert_match(/httponly/i, set_cookie)
    assert_match(/samesite=lax/i, set_cookie)
    assert_no_match(/home_session=[^\n]*domain=/i, set_cookie)

    follow_redirect!
    assert_redirected_to "http://index.example.com/"
    session = Session.last
    assert_equal [ users(:mwi), "home" ], [ session.user, session.kind ]
    assert_equal "auth.login", AuditEvent.last.action
  end

  test "a new colleague's first sign-in creates a pending user who sees waiting for access" do
    sign_in_with_entra(email: "new.colleague@tourpaq.com", name: "New Colleague")
    follow_redirect!
    assert_redirected_to "/waiting"
    follow_redirect!
    assert_select "h1", "Waiting for access"
    assert_select "button", "Sign out"
    assert_match "An admin has been told", response.body
    assert User.find_by_email("new.colleague@tourpaq.com").pending?
    assert_equal %w[user.created auth.login], AuditEvent.order(:id).last(2).map(&:action)
  end

  test "a pre-created user is bound at the first sign-in" do
    sign_in_with_entra(email: "carol@contractor.example", oid: "carol-oid")
    assert_redirected_to "/"
    assert_equal "carol-oid", users(:carol).reload.entra_oid
  end

  test "the wrong tenant is refused with a plain message" do
    sign_in_with_entra(email: "someone@other.example", tid: SecureRandom.uuid)
    assert_response :forbidden
    assert_match "not in the Tourpaq directory", response.body
    assert_nil cookies[:home_session].presence
  end

  test "a disabled user is refused" do
    sign_in_with_entra(email: "dave@tourpaq.com")
    assert_response :forbidden
    assert_match "disabled", response.body
    assert_equal "auth.login_refused", AuditEvent.last.action
  end

  test "a failed Entra sign-in is audited and shows Try again" do
    on_auth_host!
    mock_entra_failure(:invalid_credentials)
    post "/auth/entra_id"
    follow_redirect!
    assert_response :forbidden
    assert_select "a", "Try again"
    event = AuditEvent.last
    assert_equal [ "auth.login_refused", "invalid_credentials" ], [ event.action, event.data["reason"] ]
  end

  test "GET does not start a sign-in (POST only)" do
    get "/auth/entra_id"
    assert_response :not_found
  end

  test "the browser goes back to where it was going, local paths only" do
    get "/waiting?tab=all"
    assert_redirected_to "/sign_in"
    sign_in_as users(:alice)
    assert_redirected_to "/waiting?tab=all"

    sign_out
    on_auth_host!
    post "/auth/entra_id" # no return-to stored: the root, which goes on to the index host
    follow_redirect!
    assert_redirected_to "/"
  end

  test "sign out ends the auth session" do
    sign_in_as users(:alice)
    session = Session.last
    delete "/session"
    assert_redirected_to "/sign_in?stay=1"
    assert_equal "signed_out", session.reload.end_reason
    assert_equal "auth.logout", AuditEvent.last.action
    get "/"
    assert_redirected_to "/sign_in"
  end

  test "8 hours idle sends the user through Entra again" do
    sign_in_as users(:alice)
    travel 8.hours + 1.minute
    get "/"
    assert_redirected_to "/sign_in"
    assert_equal "idle", Session.last.end_reason
    assert_equal "session.expired", AuditEvent.last.action
  end

  test "7 days after the Entra sign-in the session ends, however active" do
    sign_in_as users(:alice)
    23.times do # a request every 7 hours, never idle
      travel 7.hours
      get "/"
      assert_redirected_to "http://index.example.com/", "still signed in"
    end
    travel 7.hours + 1.minute # 7 days and a minute since the Entra sign-in
    get "/"
    assert_redirected_to "/sign_in"
    assert_equal "expired", Session.last.expiry_reason # the cookie itself expires then too
  end

  test "disabling a user ends their session at the next request" do
    sign_in_as users(:alice)
    users(:alice).disable!(actor: users(:mwi))
    get "/"
    assert_redirected_to "/sign_in"
  end

  test "sign out everywhere ends the session" do
    sign_in_as users(:alice)
    users(:alice).sign_out_everywhere!(actor: users(:mwi))
    get "/"
    assert_redirected_to "/sign_in"
  end

  test "the real strategy starts with state, nonce and PKCE S256 to our tenant" do
    OmniAuth.config.test_mode = false
    with_auth_config(entra_client_id: "client-123") do
      post "/auth/entra_id"
    end
    location = URI(response.location)
    query = Rack::Utils.parse_query(location.query)
    assert_equal "login.microsoftonline.com", location.host
    assert_equal "/#{entra_tenant_id}/oauth2/v2.0/authorize", location.path
    assert_equal "http://auth.example.com/auth/entra_id/callback", query["redirect_uri"]
    assert_equal "S256", query["code_challenge_method"]
    assert query["code_challenge"].present?
    assert query["state"].present?
    assert query["nonce"].present?
    assert_equal "openid profile email", query["scope"]
  ensure
    OmniAuth.config.test_mode = true
  end

  test "the real strategy takes prompt and scope from the server, never from the browser's form" do
    OmniAuth.config.test_mode = false
    with_auth_config(entra_client_id: "client-123") do
      post "/auth/entra_id", params: { prompt: "none", scope: "openid offline_access" }
      query = Rack::Utils.parse_query(URI(response.location).query)
      assert_nil query["prompt"], "a prompt from the form is dropped"
      assert_equal "openid profile email", query["scope"]

      # A fresh sign-in asked for by an app (prompt=login) is kept in the Rails session.
      OmniAuth.config.test_mode = true
      sign_in_as users(:alice)
      get authorize_path_for(clients(:irm_web), prompt: "login")
      assert_redirected_to "/sign_in"
      OmniAuth.config.test_mode = false
      post "/auth/entra_id" # no prompt field at all: the browser left it out
      query = Rack::Utils.parse_query(URI(response.location).query)
      assert_equal "login", query["prompt"]
    end
  ensure
    OmniAuth.config.test_mode = true
  end

  test "a callback whose state does not match is refused (the real strategy)" do
    OmniAuth.config.test_mode = false
    with_auth_config(entra_client_id: "client-123") { post "/auth/entra_id" }
    get "/auth/entra_id/callback", params: { code: "abc", state: "forged" }
    assert_response :forbidden
    assert_equal "csrf_detected", AuditEvent.last.data["reason"]
  ensure
    OmniAuth.config.test_mode = true
  end
end
