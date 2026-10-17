require "test_helper"

# The admin host signs in through the app's own OIDC provider as client "admin" (SPECS.md §11.2, §22).
class AdminSsoTest < ActionDispatch::IntegrationTest
  # Admin host → home /oauth/authorize → (Entra) → admin /sso/callback. Returns the callback response.
  def admin_round_trip(user, sign_in_first: true)
    sign_in_as(user) if sign_in_first
    on_admin_host!
    get "/users?filter=pending"
    @authorize = assert_admin_sign_in_started
    get response.location # on the auth host
    if response.redirect? && !response.location.start_with?(AuthHosts.admin_callback_url)
      assert_redirected_to "/sign_in"
      sign_in_with_entra(email: user.email, name: user.name)
      follow_redirect! # back to /oauth/authorize
    end
    response
  end

  test "round trip: authorize with max_age and PKCE, the callback verifies and starts the admin session" do
    admin_round_trip(users(:mwi))
    assert_equal [ "openid email profile", "43200", "code" ], @authorize.values_at("scope", "max_age", "response_type")
    assert response.location.start_with?("#{AuthHosts.admin_callback_url}?")
    follow_redirect! # /sso/callback on the admin host
    assert_redirected_to "/users?filter=pending"
    follow_redirect!
    assert_response :success

    admin = Session.admin.last
    home = Session.home.last
    assert_equal [ users(:mwi), "admin" ], [ admin.user, admin.kind ]
    assert_in_delta home.entra_authenticated_at.to_i, admin.entra_authenticated_at.to_i, 1, "12 hours count from the Entra sign-in"
    assert_equal %w[oauth.authorized auth.login], AuditEvent.recent_first.limit(2).pluck(:action).reverse
    assert AuthorizationCode.last.used?
    assert_equal Client.admin_client, AuthorizationCode.last.client
  end

  test "an Entra sign-in older than 12 hours goes through Entra again first" do
    sign_in_as users(:mwi)
    [ 7, 6 ].each { travel _1.hours; get "/" } # the auth session stays alive (8 h idle)
    assert_redirected_to "http://index.example.com/"
    admin_round_trip(users(:mwi), sign_in_first: false)
    assert response.location.start_with?(AuthHosts.admin_callback_url)
    assert_equal "auth.login", AuditEvent.where(action: "auth.login").last.action
    assert_operator Session.home.last.entra_authenticated_at, :>, 1.minute.ago, "a fresh Entra sign-in"
    follow_redirect!
    assert_redirected_to "/users?filter=pending"
  end

  test "a non-admin is refused at authorize, audited, with no admin session" do
    admin_round_trip(users(:alice))
    assert_response :forbidden
    assert_select "h1", "You don't have access to Tourpaq Auth admin"
    assert_equal "oauth.denied", AuditEvent.last.action
    assert_not Session.admin.exists?
  end

  test "the callback checks the state" do
    admin_round_trip(users(:mwi))
    callback = URI(response.location)
    query = URI.decode_www_form(callback.query).to_h
    get "#{AuthHosts.admin_callback_url}?#{{ code: query['code'], state: 'forged' }.to_query}"
    assert_response :forbidden
    assert_select "h1", "Sign-in failed"
    assert_equal [ "auth.login_refused", "state" ], [ AuditEvent.last.action, AuditEvent.last.data["reason"] ]
    assert_not Session.admin.exists?
  end

  test "a code is used once; replaying the callback does not sign in again" do
    admin_round_trip(users(:mwi))
    callback = response.location
    follow_redirect!
    assert_response :redirect
    delete "/session" # sign out of the admin host
    get callback
    assert_response :forbidden, "no pending sign-in in this browser any more"
    assert_equal 1, Session.admin.count
  end

  test "a code for another client cannot be used at the admin callback" do
    sign_in_as users(:mwi)
    get authorize_path_for(clients(:irm_web))
    code = code_from
    on_admin_host!
    get "/"
    state = URI.decode_www_form(URI(response.location).query).to_h["state"]
    get "/sso/callback", params: { code: code, state: state }
    assert_response :forbidden
    assert_equal "invalid_grant", AuditEvent.last.data["reason"]
  end

  test "an error from the provider is shown, not trusted" do
    on_admin_host!
    get "/"
    state = URI.decode_www_form(URI(response.location).query).to_h["state"]
    get "/sso/callback", params: { error: "access_denied", state: state }
    assert_response :forbidden
    assert_select "p", /refused/
  end

  test "the admin client cannot be used over HTTP at the token endpoint" do
    admin_round_trip(users(:mwi))
    code = URI.decode_www_form(URI(response.location).query).to_h["code"]
    on_auth_host!
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: AuthHosts.admin_callback_url, client_id: "admin" }
    assert_response :unauthorized
  end
end
