require "test_helper"

# A fresh Entra sign-in (an app's prompt=login or max_age, the admin host's 12 hours) is verified with
# Entra's auth_time, not assumed because the browser was sent with prompt=login (SPECS.md §3.1, §7.6, §11.2).
# Whoever holds the browser can drop prompt=login on its way to Microsoft; Entra then signs in silently and
# its signed ID token says when credentials were really given.
class FreshSignInTest < ActionDispatch::IntegrationTest
  setup { @client = clients(:irm_web) }

  test "prompt=login: an Entra sign-in without new credentials (old auth_time) is refused" do
    sign_in_as users(:alice)
    travel 1.hour
    get authorize_path_for(@client, prompt: "login")
    assert_redirected_to "/sign_in"
    sessions = Session.home.count

    sign_in_with_entra(email: users(:alice).email, auth_time: 2.hours.ago.to_i)
    assert_response :forbidden
    assert_match "password again", response.body
    assert_equal [ "auth.login_refused", "not_fresh" ], [ AuditEvent.last.action, AuditEvent.last.data["reason"] ]
    assert_equal sessions, Session.home.count, "no new auth session"
    assert_not AuthorizationCode.exists?, "no code for the app"

    sign_in_with_entra(email: users(:alice).email) # now Microsoft did ask (auth_time = now)
    follow_redirect!
    assert client_redirect_params["code"].present?
  end

  test "a fresh sign-in is refused when Entra does not say when credentials were given (no auth_time)" do
    sign_in_as users(:alice)
    get authorize_path_for(@client, max_age: 0)
    assert_redirected_to "/sign_in"
    sign_in_with_entra(email: users(:alice).email, auth_time: nil)
    assert_response :forbidden
    assert_equal "not_fresh", AuditEvent.last.data["reason"]
  end

  test "a silent Entra sign-in keeps Entra's auth_time, so signing out and in again does not satisfy max_age" do
    sign_in_with_entra(email: users(:mwi).email, auth_time: 13.hours.ago.to_i)
    assert_response :redirect
    home = Session.home.last
    assert_in_delta 13.hours.ago.to_i, home.entra_auth_time.to_i, 2
    assert_in_delta Time.current.to_i, home.entra_authenticated_at.to_i, 2, "the session's lifetime counts from this sign-in"

    get authorize_path_for(@client, max_age: 12 * 3600)
    assert_redirected_to "/sign_in", "credentials given 13 hours ago are older than max_age"

    # Signing out and in again silently is no fresh sign-in either.
    delete session_path
    sign_in_with_entra(email: users(:mwi).email, auth_time: 13.hours.ago.to_i)
    get authorize_path_for(@client, max_age: 12 * 3600)
    assert_redirected_to "/sign_in"
  end

  test "the admin host gets no admin session from a silent Entra sign-in" do
    sign_in_with_entra(email: users(:mwi).email, auth_time: 13.hours.ago.to_i)
    on_admin_host!
    get "/users"
    authorize = response.location
    get authorize
    assert_redirected_to "/sign_in"
    sign_in_with_entra(email: users(:mwi).email, auth_time: 13.hours.ago.to_i) # prompt=login dropped by the browser
    assert_response :forbidden
    assert_not Session.admin.exists?
  end

  test "without a fresh sign-in asked for, Entra's auth_time may be old, or missing" do
    sign_in_with_entra(email: users(:alice).email, auth_time: 3.days.ago.to_i)
    assert_redirected_to "/"
    sign_out
    sign_in_with_entra(email: users(:alice).email, auth_time: nil)
    assert_redirected_to "/"
    assert_nil Session.home.last.entra_auth_time

    get authorize_path_for(@client)
    assert client_redirect_params["code"].present?
    assert_in_delta Time.current.to_i, AuthorizationCode.last.auth_time.to_i, 2, "auth_time falls back to the Entra sign-in"
  end

  test "an extension's refresh token counts from the Entra sign-in behind the session, not from an old auth_time" do
    sign_in_with_entra(email: users(:alice).email, auth_time: 6.days.ago.to_i)
    tokens = oidc_login(users(:alice), clients(:irm_extension), scope: "openid offline_access", sign_in: false)
    refresh = OauthToken.find_by_token(tokens["refresh_token"])
    assert_in_delta (Session.home.last.entra_authenticated_at + 7.days).to_i, refresh.expires_at.to_i, 5
  end
end
