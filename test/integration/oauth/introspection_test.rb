require "test_helper"

# POST /oauth/introspect (SPECS.md §9.2, §10, §22): the matrix of personal and extension tokens.
class Oauth::IntrospectionTest < ActionDispatch::IntegrationTest
  setup do
    @secret = secret_for(clients(:irm_web))
    @alice = users(:alice)
    @token = PersonalToken.issue!(user: @alice, app: apps(:irm), name: "Claude Code", scope: "read_write")
  end

  test "an active personal token: the §9.2 answer, with the role now" do
    body = introspect(@token, secret: @secret)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    record = PersonalToken.find_by_plain(@token)
    assert_equal({ "active" => true, "token_type" => "personal", "client_id" => "irm-web", "app" => "irm", "sub" => @alice.sub,
                   "email" => @alice.email, "name" => @alice.name, "scope" => "read_write", "role" => "responder",
                   "exp" => record.expires_at.to_i, "token_name" => "Claude Code" }, body)
  end

  test "the scope is reported with the role that caps it: a read_write token of a viewer" do
    Grant.create!(app: apps(:irm), subject: @alice, app_role: app_roles(:irm_viewer))
    body = introspect(@token, secret: @secret)
    assert_equal [ true, "read_write", "viewer" ], body.values_at("active", "scope", "role")
  end

  test "inactive, and nothing else, for: another app, unknown, expired, revoked, disabled user, no access" do
    kpi_secret = secret_for(clients(:kpi_web))
    assert_equal({ "active" => false }, introspect(@token, client_id: "kpi-web", secret: kpi_secret), "an IRM token presented to KPI")
    assert_equal({ "active" => false }, introspect("tpa_irm_#{SecureRandom.urlsafe_base64(32)}", secret: @secret), "unknown")
    assert_equal({ "active" => false }, introspect("garbage", secret: @secret), "not ours")

    travel 91.days do
      assert_equal({ "active" => false }, introspect(@token, secret: @secret), "expired")
    end

    Grant.create!(app: apps(:irm), subject: @alice, app_role: nil)
    assert_equal({ "active" => false }, introspect(@token, secret: @secret), "no access")
    Grant.where(subject: @alice).delete_all
    assert_equal true, introspect(@token, secret: @secret)["active"], "works again when access comes back (§6)"

    @alice.disable!(actor: users(:mwi))
    assert_equal({ "active" => false }, introspect(@token, secret: @secret), "disabled user")
    @alice.enable!(actor: users(:mwi))

    PersonalToken.find_by_plain(@token).revoke!(actor: @alice)
    assert_equal({ "active" => false }, introspect(@token, secret: @secret), "revoked")
  end

  test "a disabled app: its client is refused" do
    apps(:irm).update!(disabled_at: Time.current)
    post "/oauth/introspect", params: { token: @token }, headers: basic_auth("irm-web", @secret)
    assert_response :unauthorized
  end

  test "last_used_at is recorded at most once a minute" do
    record = PersonalToken.find_by_plain(@token)
    introspect(@token, secret: @secret)
    first = record.reload.last_used_at
    assert first.present?
    travel 30.seconds
    introspect(@token, secret: @secret)
    assert_equal first, record.reload.last_used_at
    travel 31.seconds
    introspect(@token, secret: @secret)
    assert_operator record.reload.last_used_at, :>, first
  end

  test "extension access tokens: token_type extension, scope read_write, 1 hour" do
    tokens = oidc_login(@alice, clients(:irm_extension), scope: "openid offline_access")
    body = introspect(tokens["access_token"], secret: @secret)
    assert_equal [ true, "extension", "read_write", "responder", @alice.sub ], body.values_at("active", "token_type", "scope", "role", "sub")
    assert_equal "IRM browser extension", body["token_name"]
    travel 61.minutes do
      assert_equal({ "active" => false }, introspect(tokens["access_token"], secret: @secret))
    end
    assert_equal({ "active" => false }, introspect(tokens["refresh_token"], secret: @secret), "a refresh token is no bearer token")
  end

  test "a web client's own access token is not an API token" do
    tokens = oidc_login(@alice, clients(:irm_web), secret: @secret)
    assert_equal({ "active" => false }, introspect(tokens["access_token"], secret: @secret))
  end

  test "the caller must be a web client with a valid secret" do
    post "/oauth/introspect", params: { token: @token }
    assert_response :unauthorized
    assert_match(/Basic/, response.headers["WWW-Authenticate"])
    post "/oauth/introspect", params: { token: @token }, headers: basic_auth("irm-web", "tpcs_wrong")
    assert_response :unauthorized
    post "/oauth/introspect", params: { token: @token, client_id: "irm-extension" }
    assert_response :unauthorized
    post "/oauth/introspect", params: { token: @token }, headers: basic_auth("admin", "")
    assert_response :unauthorized
    post "/oauth/introspect", params: { token: @token, client_id: "irm-web", client_secret: @secret }
    assert_response :success, "client_secret_post"
    post "/oauth/introspect", params: { token: @token, client_secret: @secret }, headers: basic_auth("irm-web", @secret)
    assert_response :unauthorized, "two authentication methods at once"
    post "/oauth/introspect", params: {}, headers: basic_auth("irm-web", @secret)
    assert_response :bad_request
  end

  test "counted per client and day, not audited" do
    assert_no_difference -> { AuditEvent.count } do
      3.times { introspect(@token, secret: @secret) }
    end
    assert_equal 3, UsageCount.find_by(client: clients(:irm_web), kind: "introspect", day: Date.current).count
  end

  test "rate limited per client" do
    600.times { post "/oauth/introspect", params: { token: "x" }, headers: basic_auth("irm-web", @secret) }
    assert_response :success
    post "/oauth/introspect", params: { token: "x" }, headers: basic_auth("irm-web", @secret)
    assert_response :too_many_requests
    kpi_secret = secret_for(clients(:kpi_web))
    post "/oauth/introspect", params: { token: "x" }, headers: basic_auth("kpi-web", kpi_secret)
    assert_response :success, "another client has its own budget"
  end
end
