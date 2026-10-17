require "test_helper"

# Nothing secret that the protocol issues reaches log/test.log (SPECS.md §14, §22): client secrets,
# authorization codes, access, refresh and ID tokens, PKCE verifiers, nonces, personal tokens and
# session cookies. The test plays every flow, then reads what it appended to the log.
class ProtocolLogSecretsTest < ActionDispatch::IntegrationTest
  LOG = Rails.root.join("log/test.log")

  test "no issued secret or token appears in log/test.log" do
    flush = -> { Rails.logger.respond_to?(:flush) && Rails.logger.flush }
    flush.call
    offset = File.exist?(LOG) ? File.size(LOG) : 0
    secrets = []

    secret = secret_for(clients(:irm_web))
    secrets << secret

    # Web client: authorize → token (basic) → userinfo → logout with id_token_hint.
    sign_in_as users(:alice)
    secrets << cookies[:home_session]
    verifier, challenge = pkce_pair
    query = authorize_query(clients(:irm_web), code_challenge: challenge, code_challenge_method: "S256")
    get "/oauth/authorize?#{query.to_query}"
    code = code_from
    secrets.push(code, verifier, query[:nonce])
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: query[:redirect_uri], code_verifier: verifier },
                         headers: basic_auth("irm-web", secret)
    web = response.parsed_body
    secrets.push(web["access_token"], web["id_token"])
    get "/oauth/userinfo", headers: { "Authorization" => "Bearer #{web['access_token']}" }
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, redirect_uri: query[:redirect_uri], code_verifier: verifier,
                                   client_id: "irm-web", client_secret: secret } # reuse, client_secret_post

    # Extension: token with a refresh token, rotation, reuse, revoke.
    ext = oidc_login(users(:alice), clients(:irm_extension), scope: "openid offline_access")
    secrets.push(ext["access_token"], ext["refresh_token"], ext["id_token"])
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: ext["refresh_token"], client_id: "irm-extension" }
    rotated = response.parsed_body
    secrets.push(rotated["access_token"], rotated["refresh_token"])
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: ext["refresh_token"], client_id: "irm-extension" }
    post "/oauth/revoke", params: { token: rotated["refresh_token"], client_id: "irm-extension" }

    # Personal token: created on the index host's Tokens page, introspected (also through an internal host), the
    # API, revoked.
    sign_in_index users(:alice), sign_in: false
    secrets << cookies[:index_session]
    post "/tokens", params: { personal_token: { app_id: apps(:irm).id, name: "MCP", scope: "read", lifetime_days: 30 } }
    personal = css_select(".link-box code").text
    secrets << personal
    on_auth_host!
    post "/oauth/introspect", params: { token: personal }, headers: basic_auth("irm-web", secret)
    post "/oauth/introspect", params: { token: ext["access_token"], client_id: "irm-web", client_secret: secret }
    get "/api/v1/access/#{users(:alice).sub}", headers: basic_auth("irm-web", secret)
    on_internal_host!
    post "/oauth/introspect", params: { token: personal }, headers: basic_auth("irm-web", secret)
    on_index_host!
    delete "/tokens/#{PersonalToken.find_by_plain(personal).id}"
    delete "/session" # the index host's sign out: an id_token_hint to the auth host's /oauth/logout
    secrets << URI.decode_www_form(URI(response.location).query).to_h["id_token_hint"]
    on_auth_host!
    get "/oauth/logout", params: { id_token_hint: web["id_token"], post_logout_redirect_uri: "https://irm.app.journeybooking.eu/" }

    # The admin host's own sign-in (state, nonce and verifier in its session; the code in-process).
    sign_in_as users(:mwi)
    on_admin_host!
    get "/"
    admin_query = URI.decode_www_form(URI(response.location).query).to_h
    get response.location
    admin_code = URI.decode_www_form(URI(response.location).query).to_h["code"]
    secrets.push(admin_code, admin_query["nonce"])
    follow_redirect!
    assert_redirected_to "/"
    secrets << cookies[:admin_session]

    flush.call
    log = File.binread(LOG, nil, offset).force_encoding("UTF-8").scrub
    assert_match "/oauth/token", log, "the flows were logged at all"
    assert_match "[FILTERED]", log
    secrets.compact.reject(&:blank?).uniq.each do |value|
      assert_not log.include?(value), "#{value.first(12)}… appears in log/test.log"
      assert_not log.include?(CGI.escape(value)), "#{value.first(12)}… (escaped) appears in log/test.log"
    end
    assert_no_match(/(tpa|tpx|tpr)_irm_[A-Za-z0-9_-]{43}/, log)
    assert_no_match(/tpcs_[A-Za-z0-9_-]{43}/, log)
  end
end
