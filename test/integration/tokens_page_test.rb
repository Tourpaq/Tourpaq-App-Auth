require "test_helper"

# The index host's Tokens page (SPECS.md §9.1, §24.1).
class TokensPageTest < ActionDispatch::IntegrationTest
  setup { sign_in_index users(:alice) }

  def create_token(**attrs)
    post "/tokens", params: { personal_token: { app_id: apps(:irm).id, name: "Claude Code", scope: "read_write", lifetime_days: 90 }.merge(attrs) }
  end

  test "the form offers only apps the user has access to" do
    get "/tokens"
    assert_response :success
    assert_select "select[name='personal_token[app_id]'] option[value!='']", 1
    assert_select "select[name='personal_token[app_id]'] option[selected]", "IRM"
    assert_select "select[name='personal_token[lifetime_days]'] option[selected]", "90 days"
  end

  test "create: shown once, stored as a digest, audited, then listed with its hint" do
    create_token
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    plain = css_select(".link-box code").text
    assert_match(/\Atpa_irm_[A-Za-z0-9_-]{43}\z/, plain)
    token = PersonalToken.find_by_plain(plain)
    assert_equal [ users(:alice), apps(:irm), "read_write", "Claude Code" ], [ token.user, token.app, token.scope, token.name ]
    assert_in_delta 90.days.from_now.to_i, token.expires_at.to_i, 5
    assert_equal "token.created", AuditEvent.last.action

    get "/tokens"
    assert_select "td.mono", "#{token.token_hint}…"
    assert_no_match plain, response.body, "never shown again"
  end

  test "an app without access, a bad lifetime or a blank name is refused with the reason" do
    create_token(app_id: apps(:kpi).id)
    assert_response :unprocessable_content
    assert_select ".errors li", /access/
    create_token(lifetime_days: 7)
    assert_response :unprocessable_content
    assert_select ".errors li", /30, 90 or 365/
    create_token(name: "")
    assert_response :unprocessable_content
    assert_equal 0, PersonalToken.count
  end

  test "at most 20 active tokens" do
    20.times { PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "t#{_1}") }
    get "/tokens"
    assert_select ".card .empty", /20 active tokens/
    create_token
    assert_response :unprocessable_content
    assert_equal 20, PersonalToken.count
  end

  test "revoke: audited, refused by introspection, shown as revoked" do
    plain = PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "MCP")
    token = PersonalToken.find_by_plain(plain)
    delete "/tokens/#{token.id}"
    assert_redirected_to "/tokens"
    assert token.reload.revoked?
    assert_equal [ "token.revoked", users(:alice) ], [ AuditEvent.last.action, AuditEvent.last.actor ]
    secret = secret_for(clients(:irm_web))
    on_auth_host!
    assert_equal({ "active" => false }, introspect(plain, secret: secret))
    on_index_host!
    get "/tokens"
    assert_select ".pill", "revoked"
  end

  test "someone else's token cannot be revoked" do
    plain = PersonalToken.issue!(user: users(:mwi), app: apps(:irm), name: "mine")
    delete "/tokens/#{PersonalToken.find_by_plain(plain).id}"
    assert_response :not_found
    assert_not PersonalToken.find_by_plain(plain).revoked?
  end

  test "a user without access sees why they cannot create one" do
    GroupMembership.create!(group: Group.create!(name: "Nothing yet"), user: users(:bob))
    reset! # another browser
    sign_in_index users(:bob)
    get "/tokens"
    assert_select ".card .empty", /no access/
  end

  test "token creation is rate limited per user" do
    10.times { |i| create_token(name: "t#{i}") }
    create_token(name: "one too many")
    assert_redirected_to "/tokens"
    assert_equal 10, PersonalToken.count
  end

  test "the tokens page needs an index session and exists on the index host only" do
    on_auth_host!
    get "/tokens"
    assert_response :not_found
    on_admin_host!
    get "/tokens"
    assert_response :redirect, "the admin host's own /tokens (admin sign-in)"
    on_index_host!
    delete "/session"
    get "/tokens"
    assert_equal [ auth_host, "/oauth/authorize" ], [ URI(response.location).host, URI(response.location).path ]
  end
end
