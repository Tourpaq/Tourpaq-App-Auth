require "test_helper"

# Discovery, JWKS and key rotation, userinfo, revocation and logout (SPECS.md §7.1, §7.3, §7.5, §14).
class Oauth::ProviderEndpointsTest < ActionDispatch::IntegrationTest
  setup do
    @secret = secret_for(clients(:irm_web))
    on_auth_host!
  end

  test "discovery: the issuer is APP_URL exactly, with the endpoints the IRM's client needs" do
    get "/.well-known/openid-configuration"
    assert_response :success
    doc = response.parsed_body
    assert_equal "http://auth.example.com", doc["issuer"]
    assert_equal "http://auth.example.com/oauth/authorize", doc["authorization_endpoint"]
    assert_equal "http://auth.example.com/oauth/token", doc["token_endpoint"]
    assert_equal "http://auth.example.com/oauth/jwks", doc["jwks_uri"]
    assert_equal "http://auth.example.com/oauth/logout", doc["end_session_endpoint"]
    assert_equal "http://auth.example.com/oauth/introspect", doc["introspection_endpoint"]
    assert_includes doc["token_endpoint_auth_methods_supported"], "client_secret_basic"
    assert_equal [ "S256" ], doc["code_challenge_methods_supported"]
    assert_includes doc["claims_supported"], "irm_role"
  end

  test "discovery and the provider live on the auth host (and the back-channel hosts) only" do
    [ admin_host, index_host ].each do |host|
      host! host
      get "/.well-known/openid-configuration"
      assert_response :not_found, host
      get "/oauth/jwks"
      assert_response :not_found, host
    end
  end

  test "JWKS: the current key, and the previous one during a rotation; tokens of both verify" do
    old_pem = OpenSSL::PKey::RSA.generate(2048).to_pem
    new_pem = OpenSSL::PKey::RSA.generate(2048).to_pem
    with_auth_config(oidc_signing_key: old_pem, oidc_previous_signing_key: nil) do
      get "/oauth/jwks"
      keys = response.parsed_body["keys"]
      assert_equal 1, keys.size
      assert_equal [ "RSA", "sig", "RS256" ], keys.first.values_at("kty", "use", "alg")
      assert_nil keys.first["d"], "no private parts"
      assert_equal JWT::JWK.new(OpenSSL::PKey::RSA.new(old_pem).public_key, nil, kid_generator: JWT::JWK::Thumbprint).kid, keys.first["kid"]
    end

    old_token = with_auth_config(oidc_signing_key: old_pem) { oidc_login(users(:alice), clients(:irm_web), secret: @secret)["id_token"] }
    with_auth_config(oidc_signing_key: new_pem, oidc_previous_signing_key: old_pem) do
      get "/oauth/jwks"
      assert_equal 2, response.parsed_body["keys"].size
      new_token = oidc_login(users(:alice), clients(:irm_web), secret: @secret, sign_in: false)["id_token"]
      assert verify_id_token(old_token, aud: "irm-web")
      assert verify_id_token(new_token, aud: "irm-web")
      assert_not_equal JWT.decode(old_token, nil, false).last["kid"], JWT.decode(new_token, nil, false).last["kid"]
    end
  end

  test "a signing key under 2048 bits is refused" do
    with_auth_config(oidc_signing_key: OpenSSL::PKey::RSA.generate(1024).to_pem) do
      assert_raises(Oidc::SigningKeys::MissingKey) { Oidc::SigningKeys.current }
    end
  end

  test "userinfo: the claims with the role as of now, for a live access token" do
    tokens = oidc_login(users(:alice), clients(:irm_web), secret: @secret)
    get "/oauth/userinfo", headers: { "Authorization" => "Bearer #{tokens['access_token']}" }
    assert_response :success
    assert_equal [ users(:alice).sub, "alice@tourpaq.com", true, "responder" ], response.parsed_body.values_at("sub", "email", "email_verified", "irm_role")

    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: app_roles(:irm_editor))
    post "/oauth/userinfo", headers: { "Authorization" => "Bearer #{tokens['access_token']}" }
    assert_equal "editor", response.parsed_body["irm_role"]

    Grant.find_by(subject: users(:alice)).update!(app_role: nil)
    get "/oauth/userinfo", headers: { "Authorization" => "Bearer #{tokens['access_token']}" }
    assert_response :unauthorized
    assert_match(/invalid_token/, response.headers["WWW-Authenticate"])

    get "/oauth/userinfo"
    assert_response :unauthorized
    get "/oauth/userinfo", headers: { "Authorization" => "Bearer #{PersonalToken.issue!(user: users(:mwi), app: apps(:irm), name: 'x')}" }
    assert_response :unauthorized, "personal tokens are not OIDC access tokens"
  end

  test "revocation: an access token issued to the client; other clients' tokens are left alone (still 200)" do
    tokens = oidc_login(users(:alice), clients(:irm_web), secret: @secret)
    kpi_secret = secret_for(clients(:kpi_web))
    post "/oauth/revoke", params: { token: tokens["access_token"] }, headers: basic_auth("kpi-web", kpi_secret)
    assert_response :ok
    assert_not OauthToken.find_by_token(tokens["access_token"]).revoked?

    post "/oauth/revoke", params: { token: tokens["access_token"] }, headers: basic_auth("irm-web", @secret)
    assert_response :ok
    assert OauthToken.find_by_token(tokens["access_token"]).revoked?

    post "/oauth/revoke", params: { token: "tpx_irm_unknown" }, headers: basic_auth("irm-web", @secret)
    assert_response :ok
    post "/oauth/revoke", params: { token: "x" }
    assert_response :unauthorized
  end

  test "logout with id_token_hint and a registered post_logout_redirect_uri ends the auth session" do
    tokens = oidc_login(users(:alice), clients(:irm_web), secret: @secret)
    home = Session.home.active.last
    get "/oauth/logout", params: { id_token_hint: tokens["id_token"], post_logout_redirect_uri: "https://irm.app.journeybooking.eu/", state: "bye" }
    assert_redirected_to "https://irm.app.journeybooking.eu/?state=bye"
    assert_equal "signed_out", home.reload.end_reason
    event = AuditEvent.last
    assert_equal [ "auth.logout", apps(:irm), "irm-web" ], [ event.action, event.app, event.data["client_id"] ]
    get "/"
    assert_redirected_to "/sign_in"
  end

  test "logout accepts an expired hint, refuses an unregistered return address" do
    tokens = oidc_login(users(:alice), clients(:irm_web), secret: @secret)
    get "/oauth/logout", params: { id_token_hint: tokens["id_token"], post_logout_redirect_uri: "https://evil.example/" }
    assert_response :bad_request
    assert Session.home.active.exists?(user: users(:alice))

    travel 1.hour
    get "/oauth/logout", params: { id_token_hint: tokens["id_token"] }
    assert_response :success
    assert_select "h1", "You are signed out"
  end

  test "logout without a valid hint asks first; a hint for someone else leaves the session alone" do
    sign_in_as users(:alice)
    get "/oauth/logout", params: { client_id: "irm-web", post_logout_redirect_uri: "https://irm.app.journeybooking.eu/" }
    assert_response :success
    assert_select "h1", "Sign out of Tourpaq?"
    assert Session.home.active.exists?(user: users(:alice))
    post "/oauth/logout", params: { client_id: "irm-web", post_logout_redirect_uri: "https://irm.app.journeybooking.eu/", state: "s" }
    assert_response :success
    assert_select "a[href='https://irm.app.journeybooking.eu/?state=s']"
    assert_not Session.home.active.exists?(user: users(:alice))

    mwi_token = Oidc::IdToken.issue(user: users(:mwi), client: clients(:irm_web), nonce: "n", auth_time: Time.current)
    sign_in_as users(:alice)
    get "/oauth/logout", params: { id_token_hint: mwi_token, post_logout_redirect_uri: "https://irm.app.journeybooking.eu/" }
    assert_redirected_to "https://irm.app.journeybooking.eu/"
    assert Session.home.active.exists?(user: users(:alice))
  end

  test "an ID token signed by another key is no hint" do
    forged = JWT.encode({ iss: AuthHosts.auth_url, sub: users(:alice).sub, aud: "irm-web", iat: Time.current.to_i, exp: 5.minutes.from_now.to_i },
                        OpenSSL::PKey::RSA.generate(2048), "RS256", { kid: Oidc::SigningKeys.current.kid })
    assert_raises(Oidc::InvalidToken) { Oidc::IdToken.verify_hint(forged) }
    sign_in_as users(:alice)
    get "/oauth/logout", params: { id_token_hint: forged }
    assert_select "h1", "Sign out of Tourpaq?"
  end
end
