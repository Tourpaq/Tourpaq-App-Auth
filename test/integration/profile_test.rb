require "test_helper"

# The profile on the index host (SPECS.md §11.1, §24.1): name and email, my access, my sessions, my extensions.
class ProfileTest < ActionDispatch::IntegrationTest
  test "shows name and email read-only and access with its source" do
    Grant.create!(app: apps(:kpi), subject: users(:alice), app_role: app_roles(:kpi_editor))
    sign_in_index users(:alice)
    get "/profile"
    assert_response :success
    assert_select "h1", "Alice Popescu"
    assert_select ".facts dd", "alice@tourpaq.com"
    assert_select "input[type=text], input[type=email], textarea", 0, "nothing to edit"
    assert_select "td", "group RO Dev"
    assert_select "td", "given to you directly"
    assert_select "a[href='/tokens']"
  end

  test "a user in a group without grants sees no access" do
    GroupMembership.create!(group: Group.create!(name: "Nothing yet"), user: users(:bob))
    sign_in_index users(:bob)
    get "/profile"
    assert_select ".empty", /No access to any app yet/
  end

  test "lists my sign-ins and index sessions and ends another one" do
    other, = Session.start!(user: users(:alice), kind: "home", user_agent: "Mozilla/5.0 (Windows NT 10.0) Firefox/130.0")
    admin_row, = Session.start!(user: users(:mwi), kind: "home")
    sign_in_index users(:alice)
    get "/profile"
    assert_select "td", /Firefox on Windows/
    assert_select ".pill", "this browser"
    assert_select ".pill", "auth"
    assert_select ".pill", "index"

    delete "/profile/sessions/#{other.id}"
    assert_redirected_to "/profile"
    assert_equal "ended_by_user", other.reload.end_reason
    assert_equal [ "session.ended", users(:alice) ], [ audit("session.ended").action, audit("session.ended").actor ]
    get "/profile"
    assert_response :success, "this browser is still signed in"

    delete "/profile/sessions/#{admin_row.id}"
    assert_response :not_found, "someone else's session"
    assert admin_row.reload.active?
  end

  test "ending this browser's index session signs out here" do
    sign_in_index users(:alice)
    current = Session.index_host.where(user: users(:alice)).last
    delete "/profile/sessions/#{current.id}"
    assert_redirected_to "/signed_out"
    assert_not current.reload.active?
    get "/profile"
    assert_equal "/oauth/authorize", URI(response.location).path
  end

  test "lists signed-in extensions and signs one out (the whole chain)" do
    refresh = create_extension_sign_in(users(:alice))
    sign_in_index users(:alice)
    get "/profile"
    assert_select "td", "IRM browser extension"

    delete "/profile/extensions/#{refresh.id}"
    assert_redirected_to "/profile"
    assert OauthToken.where(chain_id: refresh.chain_id).all?(&:revoked?)
    event = audit("oauth.revoked")
    assert_equal [ users(:alice), apps(:irm), "user" ], [ event.actor, event.app, event.data["by"] ]
    follow_redirect!
    assert_select ".empty", /No browser extension/
  end

  test "cannot sign out someone else's extension" do
    refresh = create_extension_sign_in(users(:mwi))
    sign_in_index users(:alice)
    delete "/profile/extensions/#{refresh.id}"
    assert_response :not_found
    assert_not refresh.reload.revoked?
  end

  test "the profile is on the index host only" do
    sign_in_as users(:alice)
    get "/profile"
    assert_response :not_found
    on_admin_host!
    get "/profile"
    assert_response :not_found
  end
end
