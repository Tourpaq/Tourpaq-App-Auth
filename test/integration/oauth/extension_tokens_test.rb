require "test_helper"

# Browser extensions (SPECS.md §10): public client, PKCE, access token tpx_ (1 h), rotating refresh
# token tpr_ (30 days unused, SESSION_MAX_DAYS at most), reuse detection, and the §6 effects.
class Oauth::ExtensionTokensTest < ActionDispatch::IntegrationTest
  setup do
    @client = clients(:irm_extension)
    @irm_secret = secret_for(clients(:irm_web))
  end

  def refresh(token, client_id: "irm-extension")
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: token, client_id: client_id }
    response.parsed_body
  end

  test "sign-in with PKCE and offline_access: an access token and a refresh token, bound to the app" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    assert_match(/\Atpx_irm_[A-Za-z0-9_-]{43}\z/, tokens["access_token"])
    assert_match(/\Atpr_irm_[A-Za-z0-9_-]{43}\z/, tokens["refresh_token"])
    assert_equal "openid offline_access", tokens["scope"]
    claims = verify_id_token(tokens["id_token"], aud: "irm-extension", nonce: tokens["nonce"])
    assert_equal "responder", claims["irm_role"]

    refresh = OauthToken.find_by_token(tokens["refresh_token"])
    assert_in_delta (Session.home.last.entra_authenticated_at + 7.days).to_i, refresh.expires_at.to_i, 5,
                    "SESSION_MAX_DAYS (7) after the Entra sign-in comes before 30 days unused"
    assert_equal OauthToken.find_by_token(tokens["access_token"]).chain_id, refresh.chain_id
  end

  test "without offline_access there is no refresh token" do
    tokens = oidc_login(users(:alice), @client, scope: "openid")
    assert_nil tokens["refresh_token"]
    assert tokens["access_token"].present?
  end

  test "a public client must not send a secret, and must use PKCE" do
    sign_in_as users(:alice)
    verifier, challenge = pkce_pair
    get authorize_path_for(@client, scope: "openid offline_access", code_challenge: challenge, code_challenge_method: "S256")
    code = code_from
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: OidcHelpers::EXTENSION_REDIRECT,
                                   code_verifier: verifier, client_id: "irm-extension", client_secret: "tpcs_guess" }
    assert_response :unauthorized
    assert_equal "invalid_client", response.parsed_body["error"]
  end

  test "refresh rotates: a new pair each time, the old refresh token is retired" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    first = tokens["refresh_token"]
    second = refresh(first)
    assert_response :success
    assert_match(/\Atpr_irm_/, second["refresh_token"])
    assert_match(/\Atpx_irm_/, second["access_token"])
    assert_not_equal first, second["refresh_token"]
    assert OauthToken.find_by_token(first).retired?

    third = refresh(second["refresh_token"])
    assert_response :success
    assert_equal 1, OauthToken.refresh.where(chain_id: OauthToken.find_by_token(first).chain_id, replaced_by_id: nil).count
    assert third["access_token"].present?
  end

  test "reuse of a retired refresh token revokes the whole chain and is audited" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    first = tokens["refresh_token"]
    current = refresh(first)["refresh_token"]

    refresh(first)
    assert_equal [ 400, "invalid_grant" ], [ response.status, response.parsed_body["error"] ]
    event = AuditEvent.last
    assert_equal [ "oauth.refresh_reused", users(:alice), apps(:irm), "irm-extension" ], [ event.action, event.subject, event.app, event.data["client_id"] ]

    refresh(current)
    assert_equal "invalid_grant", response.parsed_body["error"], "the legitimate holder is signed out too"
    assert_equal false, introspect(tokens["access_token"], secret: @irm_secret)["active"]
    assert OauthToken.where(chain_id: OauthToken.find_by_token(first).chain_id).all?(&:revoked?)
  end

  test "a refresh token is refused after 30 days unused, and SESSION_MAX_DAYS after the Entra sign-in" do
    with_auth_config(session_max: 90.days) do
      tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
      assert_in_delta 30.days.from_now.to_i, OauthToken.find_by_token(tokens["refresh_token"]).expires_at.to_i, 5
      travel 29.days
      token = refresh(tokens["refresh_token"])["refresh_token"]
      assert_response :success
      travel 30.days + 1.minute
      refresh(token)
      assert_equal "invalid_grant", response.parsed_body["error"]
    end

    travel_back
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    token = tokens["refresh_token"]
    6.times do
      travel 1.day + 1.hour
      body = refresh(token)
      assert_response :success
      token = body["refresh_token"]
    end
    assert OauthToken.find_by_token(token).expires_at <= Session.home.last.entra_authenticated_at + 7.days
    travel 1.day
    refresh(token)
    assert_equal "invalid_grant", response.parsed_body["error"], "never past 7 days after the Entra sign-in"
  end

  test "web clients get no refresh tokens and cannot use the refresh grant" do
    tokens = oidc_login(users(:alice), clients(:irm_web), secret: @irm_secret, scope: "openid offline_access")
    assert_nil tokens["refresh_token"]
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: "tpr_irm_x" }, headers: basic_auth("irm-web", @irm_secret)
    assert_equal "unauthorized_client", response.parsed_body["error"]
  end

  test "a refresh token is bound to its client" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    Client.create!(app: apps(:irm), client_id: "irm-extension-2", kind: "extension", redirect_uris: [ "https://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.chromiumapp.org/" ])
    refresh(tokens["refresh_token"], client_id: "irm-extension-2")
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "disabling the user revokes the extension at once" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    users(:alice).disable!(actor: users(:mwi))
    refresh(tokens["refresh_token"])
    assert_equal "invalid_grant", response.parsed_body["error"]
    assert_equal false, introspect(tokens["access_token"], secret: @irm_secret)["active"]
  end

  test "sign out everywhere revokes the extension" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    users(:alice).sign_out_everywhere!(actor: users(:mwi))
    refresh(tokens["refresh_token"])
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "removing access to the app refuses the tokens and revokes the chain at the next refresh" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: nil)
    assert_equal false, introspect(tokens["access_token"], secret: @irm_secret)["active"]
    refresh(tokens["refresh_token"])
    assert_equal "invalid_grant", response.parsed_body["error"]
    Grant.where(subject: users(:alice)).delete_all
    refresh(tokens["refresh_token"])
    assert_equal "invalid_grant", response.parsed_body["error"], "access coming back does not revive it"
  end

  test "the hourly sweep revokes tokens of users without access" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: nil)
    assert_equal 2, AccessRevocation.call
    Grant.where(subject: users(:alice)).delete_all
    refresh(tokens["refresh_token"])
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "the extension revokes its own refresh token (RFC 7009): the chain ends" do
    tokens = oidc_login(users(:alice), @client, scope: "openid offline_access")
    post "/oauth/revoke", params: { token: tokens["refresh_token"], token_type_hint: "refresh_token", client_id: "irm-extension" }
    assert_response :ok
    assert_equal "oauth.revoked", AuditEvent.last.action
    assert_equal false, introspect(tokens["access_token"], secret: @irm_secret)["active"]
  end

  test "the token endpoint is rate limited per client and address" do
    60.times { refresh("tpr_irm_unknown") }
    assert_response :bad_request
    refresh("tpr_irm_unknown")
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
  end
end
