require "test_helper"

# Web and MCP access per app, the MCP Gateway app, its token's introspection with mcp_access, and the token exchange
# (SPECS.md §25).
class McpGatewayTest < ActionDispatch::IntegrationTest
  EXCHANGE = Oidc::TokenExchange::GRANT_TYPE

  setup do
    @alice = users(:alice) # IRM responder through RO Dev (web)
    @logs = App.create!(slug: "logs", name: "Logs Analyzer", url: "https://logs.app.journeybooking.eu", mcp_channel: true,
                        roles: [ AppRole.new(key: "viewer", position: 1), AppRole.new(key: "admin", position: 2) ])
    @sql = App.create!(slug: "staging-sql", name: "Staging SQL Server", web_channel: false, mcp_channel: true,
                       roles: [ AppRole.new(key: "viewer", position: 1), AppRole.new(key: "admin", position: 2) ])
    @gateway = App.create!(slug: "mcp", name: "MCP Gateway", web_channel: false, mcp_channel: true, gateway: true,
                           roles: [ AppRole.new(key: "user", position: 1) ])
    @logs_web = Client.create!(app: @logs, client_id: "logs-web", kind: "web", name: "Logs web")
    @mcp_web = Client.create!(app: @gateway, client_id: "mcp-web", kind: "web", name: "MCP Gateway web")
    @logs_secret = secret_for(@logs_web)
    @mcp_secret = secret_for(@mcp_web)
  end

  def grant(app, subject, role, channel:) = GrantChange.set(app: app, subject: subject, role: role && app.role(role), channel: channel)

  def gateway_token(user = @alice, scope: "read_write")
    PersonalToken.issue!(user: user, app: @gateway, name: "Claude Code", scope: scope)
  end

  def exchange(subject_token, audience, client_id: "mcp-web", secret: @mcp_secret, **extra)
    post "/oauth/token", params: { grant_type: EXCHANGE, subject_token: subject_token, audience: audience,
                                   subject_token_type: Oidc::TokenExchange::ACCESS_TOKEN_TYPE }.merge(extra),
                         headers: basic_auth(client_id, secret)
    response.parsed_body
  end

  # --- Channels ---------------------------------------------------------------------------------

  test "each channel is granted on its own: web only, MCP only, both" do
    grant(@logs, @alice, "admin", channel: "mcp")
    assert_equal [ nil, "admin" ], %w[web mcp].map { EffectiveRole.for(@alice, @logs, channel: _1).role_key }

    grant(@logs, groups(:ro_dev), "viewer", channel: "web")
    assert_equal [ "viewer", "admin" ], %w[web mcp].map { EffectiveRole.for(@alice, @logs, channel: _1).role_key }
    assert_equal "viewer, from RO Dev", EffectiveRole.for(@alice, @logs).to_s, "web stays the default"

    grant(@logs, @alice, nil, channel: "mcp")
    assert_equal [ "viewer", nil ], %w[web mcp].map { EffectiveRole.for(@alice, @logs, channel: _1).role_key },
                 "a direct no access overrides the groups on its own channel only"
    assert_equal [ @logs ], EffectiveRole.apps_for(@alice).map(&:app) - [ apps(:irm) ]
    assert_empty EffectiveRole.apps_for(@alice, channel: "mcp").map(&:app)
  end

  test "an app without the channel gives nobody access on it and refuses grants for it" do
    grant = grant(apps(:irm), @alice, "viewer", channel: "mcp")
    assert_match "MCP is not a channel of IRM", grant.errors.full_messages.to_sentence
    assert_not EffectiveRole.for(users(:mwi), @sql, channel: "web").access?
    assert_equal "no access", EffectiveRole.for(@alice, apps(:irm), channel: "mcp").to_s
  end

  test "grant changes are audited with their channel" do
    grant(@logs, @alice, "viewer", channel: "mcp")
    event = AuditEvent.where(action: "grant.created").last
    assert_equal [ "mcp", nil, "viewer" ], event.data.values_at("channel", "role_before", "role_after")
    assert_equal [ "mcp", nil, "viewer" ], event.data["users"].first.values_at("channel", "before", "after")
  end

  # --- The gateway app ---------------------------------------------------------------------------

  test "gateway access follows MCP access elsewhere, and a direct no access switches it off for one person" do
    assert_not EffectiveRole.for(@alice, @gateway, channel: "mcp").access?
    grant(@sql, @alice, "viewer", channel: "mcp")
    assert_equal "user, from MCP access", EffectiveRole.for(@alice, @gateway, channel: "mcp").to_s
    assert_includes EffectiveRole.members_of(@gateway, channel: "mcp").map(&:user), @alice
    assert_includes EffectiveRole.apps_for(@alice, channel: "mcp").map(&:app), @gateway

    grant(@gateway, @alice, nil, channel: "mcp")
    assert_equal "no access (direct)", EffectiveRole.for(@alice, @gateway, channel: "mcp").to_s
    assert_not_includes EffectiveRole.members_of(@gateway, channel: "mcp").map(&:user), @alice
  end

  test "a gateway must be MCP only" do
    app = App.new(slug: "mcp2", name: "Second", web_channel: true, mcp_channel: true, gateway: true, roles: [ AppRole.new(key: "user", position: 1) ])
    assert_not app.valid?
    assert_match "MCP only", app.errors.full_messages.to_sentence
    assert_not App.new(slug: "none", name: "None", web_channel: false, mcp_channel: false, roles: [ AppRole.new(key: "x", position: 1) ]).valid?
  end

  test "the Tokens page offers the gateway and no tokens for apps behind it" do
    grant(@logs, @alice, "admin", channel: "web")
    grant(@logs, @alice, "admin", channel: "mcp")
    sign_in_index @alice
    get "/tokens"
    assert_select "select[name='personal_token[app_id]'] option", text: "MCP Gateway"
    assert_select "select[name='personal_token[app_id]'] option", text: "IRM"
    assert_select "select[name='personal_token[app_id]'] option", text: "Logs Analyzer", count: 0
    post "/tokens", params: { personal_token: { app_id: @logs.id, name: "x", scope: "read", lifetime_days: 30 } }
    assert_response :unprocessable_content

    post "/tokens", params: { personal_token: { app_id: @gateway.id, name: "Claude", scope: "read_write", lifetime_days: 365 } }
    assert_response :success
    assert_match(/\Atpa_mcp_[A-Za-z0-9_-]{43}\z/, css_select(".link-box code").text)
  end

  test "no gateway token without MCP access" do
    error = assert_raises(ActiveRecord::RecordInvalid) { gateway_token }
    assert_match "not one you have access to", error.message
  end

  # --- Introspection of a gateway token ---------------------------------------------------------

  test "introspecting a gateway token as its client adds mcp_access, by slug; inactive without any" do
    grant(@sql, @alice, "viewer", channel: "mcp")
    grant(@logs, @alice, "admin", channel: "mcp")
    token = gateway_token
    body = introspect(token, client_id: "mcp-web", secret: @mcp_secret)
    assert_equal [ true, "personal", "mcp", "user", "read_write" ], body.values_at("active", "token_type", "app", "role", "scope")
    assert_equal [ { "app" => "logs", "name" => "Logs Analyzer", "role" => "admin" },
                   { "app" => "staging-sql", "name" => "Staging SQL Server", "role" => "viewer" } ], body["mcp_access"]

    assert_equal({ "active" => false }, introspect(token, client_id: "logs-web", secret: @logs_secret), "another app's client")

    @logs.update!(disabled_at: Time.current)
    assert_equal [ "staging-sql" ], introspect(token, client_id: "mcp-web", secret: @mcp_secret)["mcp_access"].map { _1["app"] }

    GrantChange.remove(Grant.find_by!(app: @sql, subject: @alice))
    assert_equal({ "active" => false }, introspect(token, client_id: "mcp-web", secret: @mcp_secret))
  end

  # --- The token exchange ------------------------------------------------------------------------

  test "the gateway exchanges a gateway token for a short-lived token the app introspects with the MCP role" do
    grant(@logs, @alice, "viewer", channel: "web")
    grant(@logs, @alice, "admin", channel: "mcp")
    token = gateway_token
    body = exchange(token, "logs")
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match(/\Atpe_logs_[A-Za-z0-9_-]{43}\z/, body["access_token"])
    assert_equal [ Oidc::TokenExchange::ACCESS_TOKEN_TYPE, "Bearer", 300, "read_write" ],
                 body.values_at("issued_token_type", "token_type", "expires_in", "scope")
    assert_not ExchangedToken.exists?(token_digest: body["access_token"]), "stored as a digest only"

    answer = introspect(body["access_token"], client_id: "logs-web", secret: @logs_secret)
    assert_equal({ "active" => true, "token_type" => "exchanged", "client_id" => "logs-web", "app" => "logs", "sub" => @alice.sub,
                   "email" => @alice.email, "name" => @alice.name, "scope" => "read_write", "role" => "admin",
                   "exp" => ExchangedToken.last.expires_at.to_i, "token_name" => "Claude Code", "act" => { "client_id" => "mcp-web" } }, answer)
    assert_equal({ "active" => false }, introspect(body["access_token"], client_id: "mcp-web", secret: @mcp_secret), "only the audience's client")

    event = AuditEvent.where(action: "token.exchanged").last
    assert_equal [ @alice, @logs, "logs", "mcp-web" ], [ event.actor, event.app, event.data["audience"], event.data["client_id"] ]
    exchange(token, "logs")
    assert_equal 1, AuditEvent.where(action: "token.exchanged").count, "at most once per token, app and 5 minutes"
    assert_equal 2, UsageCount.find_by!(client: @mcp_web, kind: "exchange").count
  end

  test "the exchanged token dies with the gateway token, the MCP role, or its five minutes" do
    grant(@logs, @alice, "admin", channel: "mcp")
    grant(@sql, @alice, "viewer", channel: "mcp")
    token = gateway_token
    live = ->(plain) { introspect(plain, client_id: "logs-web", secret: @logs_secret)["active"] }

    plain = exchange(token, "logs")["access_token"]
    travel 6.minutes do
      assert_not live.(plain), "expired"
    end

    plain = exchange(token, "logs")["access_token"]
    grant(@logs, @alice, nil, channel: "mcp")
    assert_not live.(plain), "MCP access removed (the web channel does not count)"
    GrantChange.remove(Grant.find_by!(app: @logs, subject: @alice, channel: "mcp"))
    grant(@logs, @alice, "viewer", channel: "mcp")
    assert live.(plain), "back with the role"

    PersonalToken.find_by_plain(token).revoke!(actor: @alice)
    assert_not live.(plain), "gateway token revoked"
    assert_equal 0, ExchangedToken.count
  end

  test "refusals: the wrong client, subject token or audience" do
    grant(@logs, @alice, "viewer", channel: "web")
    grant(@sql, @alice, "viewer", channel: "mcp")
    token = gateway_token

    assert_equal "unauthorized_client", exchange(token, "staging-sql", client_id: "logs-web", secret: @logs_secret)["error"]
    assert_response :bad_request
    assert_equal "invalid_client", exchange(token, "staging-sql", secret: "wrong")["error"]
    assert_response :unauthorized

    assert_equal "invalid_grant", exchange("tpa_mcp_#{SecureRandom.urlsafe_base64(32)}", "staging-sql")["error"]
    irm_token = PersonalToken.issue!(user: @alice, app: apps(:irm), name: "IRM")
    assert_equal "invalid_grant", exchange(irm_token, "staging-sql")["error"], "not a gateway token"

    assert_equal "invalid_target", exchange(token, "logs")["error"], "a web role is not MCP access"
    assert_equal "invalid_target", exchange(token, "irm")["error"], "no MCP channel"
    assert_equal "invalid_target", exchange(token, "mcp")["error"], "never the gateway itself"
    assert_equal "invalid_target", exchange(token, "nope")["error"]
    assert_equal "invalid_request", exchange(token, "staging-sql", subject_token_type: "urn:x")["error"]

    users(:alice).disable!(reason: "test")
    assert_equal "invalid_grant", exchange(token, "staging-sql")["error"]
    assert_equal 0, ExchangedToken.count
  end

  test "the exchanged scope is the gateway token's when the app has it, else the app's lowest" do
    @sql.update!(token_scope_list: "public all")
    grant(@sql, @alice, "viewer", channel: "mcp")
    grant(@logs, @alice, "viewer", channel: "mcp")
    token = gateway_token(scope: "read")
    assert_equal "read", exchange(token, "logs")["scope"]
    assert_equal "public", exchange(gateway_token, "staging-sql")["scope"]
  end

  test "discovery lists the token exchange" do
    get "/.well-known/openid-configuration"
    assert_includes response.parsed_body["grant_types_supported"], EXCHANGE
  end

  test "the subject token never reaches the log" do
    grant(@sql, @alice, "viewer", channel: "mcp")
    token = gateway_token
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    old, Rails.logger = Rails.logger, logger
    ActionController::Base.logger = ActionController::API.logger = logger
    plain = exchange(token, "staging-sql")["access_token"]
    assert_not_includes io.string, token
    assert_not_includes io.string, plain
  ensure
    Rails.logger = old
    ActionController::Base.logger = ActionController::API.logger = old
  end

  # --- Admin -------------------------------------------------------------------------------------

  test "admins set an MCP grant on the user's page" do
    sign_in_admin users(:mwi)
    get "/users/#{@alice.id}"
    assert_select "select#grant_role_#{@logs.id}_mcp"
    assert_select "select#grant_role_#{apps(:irm).id}_mcp", count: 0
    post "/grants", params: { app_id: @logs.id, subject_type: "User", subject_id: @alice.id, channel: "mcp", role: "admin" }
    assert_equal "Logs Analyzer (MCP): Alice Popescu now has admin.", flash[:notice]
    assert_equal "admin", EffectiveRole.for(@alice, @logs, channel: "mcp").role_key
    post "/grants", params: { app_id: apps(:irm).id, subject_type: "User", subject_id: @alice.id, channel: "mcp", role: "viewer" }
    assert_match "not a channel of IRM", flash[:alert]

    get "/access"
    assert_response :success
    get "/access.csv"
    assert_includes response.body.lines.first, "logs mcp,logs mcp source"
    get "/apps/#{@logs.id}/members", params: { channel: "mcp" }
    assert_select "td", text: @alice.email
  end
end
