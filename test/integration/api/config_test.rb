require "test_helper"

# The config API (SPECS.md §25.7): this app's access setup for its admins, through the MCP Gateway with a token
# exchanged for auth-config. Never a secret in an answer.
class Api::ConfigTest < ActionDispatch::IntegrationTest
  setup do
    @gateway = App.create!(slug: "mcp", name: "MCP Gateway", web_channel: false, mcp_channel: true, gateway: true,
                           roles: [ AppRole.new(key: "user", position: 1) ])
    @config = App.create!(slug: "auth-config", name: "Tourpaq Auth configuration", web_channel: false, mcp_channel: true,
                          roles: [ AppRole.new(key: "admin", position: 1) ])
    @mcp_web = Client.create!(app: @gateway, client_id: "mcp-web", kind: "web", name: "MCP Gateway web")
    @mcp_secret = secret_for(@mcp_web)
    @irm_secret = secret_for(clients(:irm_web))
    [ users(:mwi), users(:alice) ].each do |user|
      GrantChange.set(app: @config, subject: user, role: @config.role("admin"), channel: "mcp")
    end
    on_auth_host!
  end

  # A gateway token for the user, exchanged for auth-config: the Bearer the gateway sends.
  def config_token(user)
    plain = PersonalToken.issue!(user: user, app: @gateway, name: "Claude Code", scope: "read")
    post "/oauth/token", params: { grant_type: Oidc::TokenExchange::GRANT_TYPE, subject_token: plain, audience: "auth-config",
                                   subject_token_type: Oidc::TokenExchange::ACCESS_TOKEN_TYPE },
                         headers: basic_auth("mcp-web", @mcp_secret)
    assert_response :success
    response.parsed_body["access_token"].tap { assert_match(/\Atpe_auth-config_/, _1) }
  end

  def get_config(path, token)
    get "/api/v1/config#{path}", headers: { "Authorization" => "Bearer #{token}" }
    response.parsed_body
  end

  test "an admin reads the overview: apps with channels, roles and clients, groups, admins; no secret anywhere" do
    body = get_config("", config_token(users(:mwi)))
    assert_response :success
    irm = body["apps"].find { _1["slug"] == "irm" }
    assert_equal %w[web], irm["channels"]
    client = irm["clients"].find { _1["client_id"] == "irm-web" }
    assert_equal 1, client["secrets"]["active"]
    assert_includes body["groups"].map { _1["name"] }, "DK Tech"
    assert_includes body["admins"].map { _1["email"] }, "mwi@tourpaq.com"

    text = response.body
    assert_not_includes text, @irm_secret
    assert_not_includes text, @mcp_secret
    assert_not_includes text, ClientSecret.first.hint
    assert_no_match(/secret_digest|token_digest|token_hint|entra_oid/, text)
  end

  test "one app: grants and effective members per channel, with where each role comes from" do
    body = get_config("/apps/auth-config", config_token(users(:mwi)))
    assert_response :success
    assert_equal %w[mcp], body["channels"]
    assert_includes body["grants"], { "channel" => "mcp", "role" => "admin", "subject_type" => "person", "subject" => "alice@tourpaq.com" }
    member = body["members"]["mcp"].find { _1["email"] == "mwi@tourpaq.com" }
    assert_equal [ "admin", "direct" ], member.values_at("role", "source")

    get_config("/apps/nope", config_token(users(:mwi)))
    assert_response :not_found
  end

  test "one person by email or sub: groups, grants, access per channel, personal tokens without the token" do
    alice_plain = PersonalToken.issue!(user: users(:alice), app: @gateway, name: "Claude Code", scope: "read")
    token = config_token(users(:mwi))
    body = get_config("/users/alice@tourpaq.com", token)
    assert_not_includes response.body, alice_plain
    assert_response :success
    assert_equal [ "alice@tourpaq.com", false ], body["user"].values_at("email", "admin")
    assert_includes body["access"], { "channel" => "mcp", "role" => "admin", "source" => "direct", "app" => "auth-config" }
    assert_includes body["access"].map { _1["app"] }, "irm"
    tokens = body["personal_tokens"]
    assert_equal [ "Claude Code" ], tokens.map { _1["name"] }.uniq
    assert_no_match(/tpa_mcp_|plain|digest|hint/, response.body)

    assert_equal "alice@tourpaq.com", get_config("/users/#{users(:alice).sub}", token).dig("user", "email")
    get_config("/users/nobody@tourpaq.com", token)
    assert_response :not_found
  end

  test "one group: members and grants" do
    body = get_config("/groups/#{ERB::Util.url_encode('DK Tech')}", config_token(users(:mwi)))
    assert_response :success
    assert_includes body["members"].map { _1["email"] }, "mwi@tourpaq.com"
  end

  test "whoami names the admin; reads are audited at most once per five minutes" do
    token = config_token(users(:mwi))
    assert_difference -> { AuditEvent.where(action: "config.read").count }, 1 do
      assert_equal "mwi@tourpaq.com", get_config("/whoami", token)["email"]
      get_config("", token)
    end
    event = AuditEvent.where(action: "config.read").last
    assert_equal [ users(:mwi), @config, "mcp-web" ], [ event.actor, event.app, event.data["client_id"] ]
  end

  test "a person who is not a Tourpaq Auth admin is refused, whatever their role in auth-config" do
    get_config("", config_token(users(:alice)))
    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body["error"]
    assert_equal 0, AuditEvent.where(action: "config.read").count
  end

  test "an admin who loses MCP access, or is no longer admin, is refused at once" do
    token = config_token(users(:mwi))
    users(:mwi).update_columns(admin: false)
    get_config("", token)
    assert_response :forbidden

    users(:mwi).update_columns(admin: true)
    GrantChange.set(app: @config, subject: users(:mwi), role: nil, channel: "mcp")
    get_config("", token)
    assert_response :unauthorized
  end

  test "only a token exchanged for auth-config: not a gateway token, an IRM token, Basic or nothing" do
    plain = PersonalToken.issue!(user: users(:mwi), app: @gateway, name: "Claude Code", scope: "read")
    get_config("", plain)
    assert_response :unauthorized

    get "/api/v1/config", headers: basic_auth("irm-web", @irm_secret)
    assert_response :unauthorized
    get "/api/v1/config"
    assert_response :unauthorized
    get_config("", "tpe_auth-config_#{SecureRandom.urlsafe_base64(32)}")
    assert_response :unauthorized
  end

  test "only on the back-channel hosts" do
    token = config_token(users(:mwi))
    on_index_host!
    get "/api/v1/config", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :not_found
  end
end
