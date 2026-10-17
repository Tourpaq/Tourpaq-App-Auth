require "test_helper"

# GET /oauth/authorize and the code flow round trip (SPECS.md §7.2, §7.3, §14, §22).
class Oauth::AuthorizeTest < ActionDispatch::IntegrationTest
  setup do
    @client = clients(:irm_web)
    @secret = secret_for(@client)
  end

  test "full round trip: authorize, exchange with client_secret_basic, verify the ID token with the JWKS" do
    sign_in_as users(:alice)
    verifier, challenge = pkce_pair
    query = authorize_query(@client, code_challenge: challenge, code_challenge_method: "S256")
    get "/oauth/authorize?#{query.to_query}"

    assert_response :redirect
    back = URI(response.location)
    assert_equal "https://irm.app.journeybooking.eu/sso/callback", "#{back.scheme}://#{back.host}#{back.path}"
    params = client_redirect_params
    assert_equal query[:state], params["state"]
    assert_match(/\A[A-Za-z0-9_-]{43}\z/, params["code"])
    assert_equal [ "oauth.authorized", apps(:irm) ], [ AuditEvent.last.action, AuditEvent.last.app ]

    post "/oauth/token", params: { grant_type: "authorization_code", code: params["code"], redirect_uri: query[:redirect_uri], code_verifier: verifier },
                         headers: basic_auth("irm-web", @secret)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal "Bearer", body["token_type"]
    assert_match(/\Atpx_irm_/, body["access_token"])
    assert_equal 3600, body["expires_in"]
    assert_nil body["refresh_token"], "web clients get no refresh token"

    claims = verify_id_token(body["id_token"], aud: "irm-web", nonce: query[:nonce])
    alice = users(:alice)
    assert_equal AuthHosts.auth_url, claims["iss"]
    assert_equal alice.sub, claims["sub"]
    assert_equal "responder", claims["irm_role"]
    assert_nil claims["kpi_role"], "nothing about other apps"
    assert_equal [ alice.email, true, alice.name, alice.upn ], claims.values_at("email", "email_verified", "name", "preferred_username")
    assert_equal 300, claims["exp"] - claims["iat"]
    assert_in_delta Session.home.last.entra_authenticated_at.to_i, claims["auth_time"], 1
    assert_not claims.key?("sessions_valid_after"), "left out until the first sign out everywhere"
  end

  test "a role claim named like a standard claim never replaces it (a row that predates the validation)" do
    apps(:irm).update_column(:role_claim, "sub")
    tokens = oidc_login(users(:alice), @client, secret: @secret)
    claims = verify_id_token(tokens["id_token"], aud: "irm-web")
    assert_equal users(:alice).sub, claims["sub"]
    assert_not claims.value?("responder"), "the role is left out rather than overwrite sub"

    get "/oauth/userinfo", headers: { "Authorization" => "Bearer #{tokens['access_token']}" }
    assert_equal users(:alice).sub, response.parsed_body["sub"]

    apps(:irm).update_column(:role_claim, "nonce")
    tokens = oidc_login(users(:alice), @client, secret: @secret)
    claims = verify_id_token(tokens["id_token"], aud: "irm-web", nonce: tokens["nonce"])
    assert_equal tokens["nonce"], claims["nonce"], "the nonce survives, so the app's login still works"
  end

  test "the ID token's kid is the signing key's thumbprint, and the header names RS256" do
    tokens = oidc_login(users(:alice), @client, secret: @secret)
    header = JSON.parse(Base64.urlsafe_decode64(tokens["id_token"].split(".").first))
    assert_equal [ "RS256", Oidc::SigningKeys.current.kid ], header.values_at("alg", "kid")
  end

  test "sessions_valid_after is in the ID token after a sign out everywhere" do
    travel_to 1.minute.ago.change(usec: 366_000), with_usec: true do
      users(:alice).sign_out_everywhere!(actor: users(:mwi))
    end
    tokens = oidc_login(users(:alice), @client, secret: @secret)
    claims = verify_id_token(tokens["id_token"], aud: "irm-web")
    assert_equal users(:alice).reload.sessions_valid_after.to_i + 1, claims["sessions_valid_after"], "rounded up, as in the access API"
  end

  test "client_secret_post works too, and either of two active secrets" do
    second = secret_for(@client)
    sign_in_as users(:alice)
    [ @secret, second ].each do |secret|
      verifier, challenge = pkce_pair
      get authorize_path_for(@client, code_challenge: challenge, code_challenge_method: "S256")
      post "/oauth/token", params: { grant_type: "authorization_code", code: code_from, redirect_uri: OidcHelpers::IRM_REDIRECT,
                                     code_verifier: verifier, client_id: "irm-web", client_secret: secret }
      assert_response :success
    end
  end

  test "PKCE is optional for a web client, but then no verifier may be sent" do
    sign_in_as users(:alice)
    get authorize_path_for(@client)
    code = code_from
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: OidcHelpers::IRM_REDIRECT },
                         headers: basic_auth("irm-web", @secret)
    assert_response :success

    get authorize_path_for(@client)
    post "/oauth/token", params: { grant_type: "authorization_code", code: code_from, redirect_uri: OidcHelpers::IRM_REDIRECT,
                                   code_verifier: SecureRandom.urlsafe_base64(48) }, headers: basic_auth("irm-web", @secret)
    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "PKCE failures: a wrong verifier, a missing verifier, plain, a malformed challenge" do
    sign_in_as users(:alice)
    _verifier, challenge = pkce_pair
    get authorize_path_for(@client, code_challenge: challenge, code_challenge_method: "S256")
    post "/oauth/token", params: { grant_type: "authorization_code", code: code_from, redirect_uri: OidcHelpers::IRM_REDIRECT,
                                   code_verifier: SecureRandom.urlsafe_base64(48) }, headers: basic_auth("irm-web", @secret)
    assert_equal [ 400, "invalid_grant", "PKCE verification failed" ], [ response.status, *response.parsed_body.values_at("error", "error_description") ]

    get authorize_path_for(@client, code_challenge: challenge, code_challenge_method: "S256")
    post "/oauth/token", params: { grant_type: "authorization_code", code: code_from, redirect_uri: OidcHelpers::IRM_REDIRECT },
                         headers: basic_auth("irm-web", @secret)
    assert_equal "invalid_grant", response.parsed_body["error"]

    get authorize_path_for(@client, code_challenge: challenge, code_challenge_method: "plain")
    assert_equal [ "invalid_request", "code_challenge_method must be S256" ], client_redirect_params.values_at("error", "error_description")

    get authorize_path_for(@client, code_challenge: "short", code_challenge_method: "S256")
    assert_equal "invalid_request", client_redirect_params["error"]
  end

  test "PKCE is required for public clients" do
    sign_in_as users(:alice)
    get authorize_path_for(clients(:irm_extension), scope: "openid offline_access")
    params = client_redirect_params
    assert_equal [ "invalid_request", nil ], params.values_at("error", "code")
    assert URI(response.location).to_s.start_with?(OidcHelpers::EXTENSION_REDIRECT)
  end

  test "a wrong or unknown redirect URI gets our error page and is never redirected to" do
    sign_in_as users(:alice)
    [ "https://evil.example/cb", "https://irm.app.journeybooking.eu/sso/callback/", "https://irm.app.journeybooking.eu/sso/callback?x=1",
      "https://kpi.app.journeybooking.eu/sso/callback", nil ].each do |uri|
      get authorize_path_for(@client, redirect_uri: uri)
      assert_response :bad_request, uri.inspect
      assert_select "h1", "Sign-in request refused"
    end
    get authorize_path_for(@client, client_id: "nope")
    assert_response :bad_request
  end

  test "the redirect URI at the token endpoint must be the one of the authorization request" do
    sign_in_as users(:alice)
    get authorize_path_for(@client)
    post "/oauth/token", params: { grant_type: "authorization_code", code: code_from, redirect_uri: "http://localhost:3030/sso/callback" },
                         headers: basic_auth("irm-web", @secret)
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "a code works once; a second use is refused and revokes what the first one issued" do
    sign_in_as users(:alice)
    get authorize_path_for(@client)
    code = code_from
    exchange = -> { post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: OidcHelpers::IRM_REDIRECT }, headers: basic_auth("irm-web", @secret) }
    exchange.call
    assert_response :success
    access = response.parsed_body["access_token"]

    exchange.call
    assert_equal [ 400, "invalid_grant" ], [ response.status, response.parsed_body["error"] ]
    assert OauthToken.find_by_token(access).revoked?
  end

  test "a code lives 60 seconds" do
    sign_in_as users(:alice)
    get authorize_path_for(@client)
    code = code_from
    travel 61.seconds
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: OidcHelpers::IRM_REDIRECT }, headers: basic_auth("irm-web", @secret)
    assert_equal [ "invalid_grant", "The authorization code has expired" ], response.parsed_body.values_at("error", "error_description")
  end

  test "a code is bound to its client" do
    sign_in_as users(:mwi)
    get authorize_path_for(@client)
    code = code_from
    kpi_secret = secret_for(clients(:kpi_web))
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: OidcHelpers::IRM_REDIRECT }, headers: basic_auth("kpi-web", kpi_secret)
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "without an auth session the user signs in with Entra first and comes back to the request" do
    on_auth_host!
    path = authorize_path_for(@client)
    get path
    assert_redirected_to "/sign_in"
    get "/sign_in"
    assert_select "form[data-controller='autosubmit']", 1, "an app sent the user: straight on to Microsoft"
    sign_in_with_entra(email: users(:alice).email, name: users(:alice).name)
    assert_redirected_to path
    follow_redirect!
    assert client_redirect_params["code"].present?
  end

  test "no access: our own page, audited oauth.denied, nothing sent back to the app" do
    sign_in_as users(:bob)
    get authorize_path_for(@client)
    assert_response :forbidden
    assert_select "h1", "You don't have access to IRM"
    assert_select "a[href='/']"
    event = AuditEvent.last
    assert_equal [ "oauth.denied", users(:bob), apps(:irm), "irm-web" ], [ event.action, event.actor, event.app, event.data["client_id"] ]
    assert_equal 0, AuthorizationCode.count
  end

  test "a direct no-access grant overrides the group, and a disabled app gets no codes" do
    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: nil)
    sign_in_as users(:alice)
    get authorize_path_for(@client)
    assert_response :forbidden

    apps(:kpi).update!(disabled_at: Time.current)
    sign_in_as users(:mwi)
    get authorize_path_for(clients(:kpi_web))
    assert_response :bad_request
  end

  test "prompt=none: login_required without a session, access_denied without access, a code otherwise" do
    on_auth_host!
    get authorize_path_for(@client, prompt: "none")
    assert_equal "login_required", client_redirect_params["error"]

    sign_in_as users(:bob)
    get authorize_path_for(@client, prompt: "none", state: "s1")
    assert_equal [ "access_denied", "s1" ], client_redirect_params.values_at("error", "state")
    assert_equal "oauth.denied", AuditEvent.last.action

    sign_in_as users(:alice)
    get authorize_path_for(@client, prompt: "none")
    assert client_redirect_params["code"].present?
  end

  test "max_age: an older Entra sign-in goes through Entra again (prompt=login), then the code carries the new auth_time" do
    sign_in_as users(:alice)
    travel 2.hours
    path = authorize_path_for(@client, max_age: 3600)
    get path
    assert_redirected_to "/sign_in"
    get "/sign_in"
    assert_response :success, "a signed-in user is not bounced to the launcher when a fresh sign-in is asked for"
    assert_select "p.hint", /password again/

    sign_in_with_entra(email: users(:alice).email)
    follow_redirect!
    code = AuthorizationCode.last
    assert code.present?
    assert_in_delta Time.current.to_i, code.auth_time.to_i, 2

    get path
    assert client_redirect_params["code"].present?, "the new sign-in is recent enough"
  end

  test "max_age with prompt=none is login_required" do
    sign_in_as users(:alice)
    travel 2.hours
    get authorize_path_for(@client, max_age: 3600, prompt: "none")
    assert_equal "login_required", client_redirect_params["error"]
  end

  test "prompt=login asks Entra again once, not in a loop" do
    sign_in_as users(:alice)
    get authorize_path_for(@client, prompt: "login")
    assert_redirected_to "/sign_in"
    return_to = session[:return_to]
    assert_match(/reauth=/, return_to)
    sign_in_with_entra(email: users(:alice).email)
    assert_redirected_to return_to
    follow_redirect!
    assert client_redirect_params["code"].present?
  end

  test "a made-up reauth marker does not skip prompt=login" do
    sign_in_as users(:alice)
    get "#{authorize_path_for(@client, prompt: 'login')}&reauth=#{Time.current.to_i}"
    assert_redirected_to "/sign_in"
  end

  test "malformed requests go back to the app with an error and the state" do
    sign_in_as users(:alice)
    { { response_type: "token" } => "unsupported_response_type", { scope: "email" } => "invalid_scope",
      { nonce: nil } => "invalid_request", { prompt: "none login" } => "invalid_request", { max_age: "soon" } => "invalid_request" }.each do |overrides, error|
      get authorize_path_for(@client, state: "keep", **overrides)
      assert_equal [ error, "keep" ], client_redirect_params.values_at("error", "state"), overrides.inspect
    end
    get authorize_path_for(@client, state: nil)
    assert_equal "invalid_request", client_redirect_params["error"]
  end

  test "a disabled user's session is gone, so they cannot authorize" do
    sign_in_as users(:alice)
    users(:alice).disable!(actor: users(:mwi))
    get authorize_path_for(@client, prompt: "none")
    assert_equal "login_required", client_redirect_params["error"]
  end

  test "a code is refused when the user lost access, or their session ended, before the exchange" do
    sign_in_as users(:alice)
    get authorize_path_for(@client)
    code = code_from
    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: nil)
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: OidcHelpers::IRM_REDIRECT }, headers: basic_auth("irm-web", @secret)
    assert_equal "invalid_grant", response.parsed_body["error"]

    Grant.where(subject: users(:alice)).delete_all
    get authorize_path_for(@client)
    code = code_from
    delete "/session"
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: OidcHelpers::IRM_REDIRECT }, headers: basic_auth("irm-web", @secret)
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "the authorize endpoint is rate limited per address" do
    on_auth_host!
    60.times { get authorize_path_for(@client, prompt: "none") }
    assert_response :redirect
    get authorize_path_for(@client, prompt: "none")
    assert_response :too_many_requests
  end
end
