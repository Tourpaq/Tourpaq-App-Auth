require "test_helper"

# Admin: users (SPECS.md §11.2).
class Admin::UsersTest < ActionDispatch::IntegrationTest
  setup { sign_in_admin users(:mwi) }

  test "the list shows pending users first, with the count in the sidebar" do
    get "/users"
    assert_response :success
    # Bob signed in and got nothing; Carol was added in advance and has nothing yet either.
    assert_select "a.nav-item[href='/users'] .nav-count", "2"
    names = css_select(".users-table tbody tr td:first-child a").map(&:text)
    assert_equal [ "Bob Ionescu", "Carol" ], names.first(2)
    assert_select "tr.row-pending", 2
    assert_select ".pill", "disabled"
    assert_select ".pill", "not signed in yet"
  end

  test "filters: pending, disabled, admins, not signed in, per app, per group, search" do
    { "pending" => [ "Bob Ionescu", "Carol" ], "disabled" => [ "Dave" ], "admins" => [ "Jacob", "Mogens Winther" ], "unbound" => [ "Carol" ] }.each do |filter, expected|
      get "/users", params: { filter: filter }
      assert_equal expected, css_select(".users-table tbody td:first-child a").map(&:text), filter
    end
    get "/users", params: { app_id: apps(:irm).id }
    assert_equal [ "Alice Popescu", "Jacob", "Mogens Winther" ], css_select(".users-table tbody td:first-child a").map(&:text)
    assert_select ".users-table td", /from RO Dev/
    get "/users", params: { group_id: groups(:ro_dev).id }
    assert_equal [ "Alice Popescu", "Dave" ], css_select(".users-table tbody td:first-child a").map(&:text)
    get "/users", params: { q: "CONTRACTOR" }
    assert_equal [ "Carol" ], css_select(".users-table tbody td:first-child a").map(&:text)
  end

  test "the user page: effective access with source, direct grants, groups, sessions, tokens, extensions" do
    alice = users(:alice)
    Grant.create!(app: apps(:kpi), subject: alice, app_role: nil)
    Session.start!(user: alice, kind: "home", user_agent: "Mozilla/5.0 (Macintosh; Mac OS X) Safari/605")
    create_personal_token(alice, apps(:irm), name: "MCP laptop")
    create_extension_sign_in(alice)
    get "/users/#{alice.id}"
    assert_response :success
    assert_select "h1", "Alice Popescu"
    assert_select ".access-table td", /from RO Dev/
    assert_select ".access-table td", /no access \(direct\)/
    assert_select ".chip a", "RO Dev"
    assert_select "td", /Safari on macOS/
    assert_select "td", "MCP laptop"
    assert_select "td.mono", "irm-extension"
    assert_select "button", "Disable"
    assert_select "button", "Make admin"
    assert_select "button", "Sign out everywhere"
  end

  test "add a user by email in advance (pre-created)" do
    get "/users/new"
    assert_response :success
    assert_difference -> { User.count } do
      post "/users", params: { user: { email: " New.Person@Contractor.example ", name: "New Person" } }
    end
    user = User.find_by_email("new.person@contractor.example")
    assert_redirected_to "/users/#{user.id}"
    assert_not user.bound?
    assert user.pending?
    event = audit("user.precreated")
    assert_equal [ user, users(:mwi), "admin" ], [ event.subject, event.actor, event.channel ]
  end

  test "adding an existing email goes to that user; a bad email is re-rendered" do
    assert_no_difference -> { User.count } do
      post "/users", params: { user: { email: "ALICE@tourpaq.com" } }
    end
    assert_redirected_to "/users/#{users(:alice).id}"
    post "/users", params: { user: { email: "not an email" } }
    assert_response :unprocessable_entity
    assert_select ".errors"
  end

  test "disable and enable" do
    alice = users(:alice)
    session, = Session.start!(user: alice, kind: "home")
    refresh = create_extension_sign_in(alice)
    post "/users/#{alice.id}/disable"
    assert_redirected_to "/users/#{alice.id}"
    assert alice.reload.disabled?
    assert_not session.reload.active?
    assert refresh.reload.revoked?
    assert_equal users(:mwi), audit("user.disabled").actor

    post "/users/#{alice.id}/enable"
    assert alice.reload.active?
    assert_equal users(:mwi), audit("user.enabled").actor
  end

  test "make admin and remove admin" do
    post "/users/#{users(:alice).id}/make_admin"
    assert users(:alice).reload.admin?
    assert audit("user.admin_granted")
    post "/users/#{users(:jjr).id}/remove_admin"
    assert_not users(:jjr).reload.admin?
    assert_equal users(:jjr), audit("user.admin_revoked").subject
  end

  test "you cannot disable yourself or remove your own admin rights" do
    post "/users/#{users(:mwi).id}/disable"
    assert_redirected_to "/users/#{users(:mwi).id}"
    assert_equal "You cannot disable yourself.", flash[:alert]
    post "/users/#{users(:mwi).id}/remove_admin"
    assert_match "your own admin rights", flash[:alert]
    assert users(:mwi).reload.admin? && users(:mwi).active?
  end

  # The signed-in admin is always an active admin, so the last active admin can only be the one
  # acting: refused by the self rule first, and by the model's validation behind it.
  test "the last active admin cannot be disabled or lose admin" do
    users(:jjr).update_columns(admin: false)
    assert User.last_active_admin?(users(:mwi))
    post "/users/#{users(:mwi).id}/disable"
    assert flash[:alert].present?
    post "/users/#{users(:mwi).id}/remove_admin"
    assert flash[:alert].present?
    assert users(:mwi).reload.admin? && users(:mwi).active?
    get "/users/#{users(:mwi).id}"
    assert_select "button[disabled]", "Disable"
    assert_select "button[disabled]", "Remove admin"
  end

  test "sign out everywhere" do
    alice = users(:alice)
    session, = Session.start!(user: alice, kind: "home")
    refresh = create_extension_sign_in(alice)
    token = create_personal_token(alice, apps(:irm))
    post "/users/#{alice.id}/sign_out_everywhere"
    assert_redirected_to "/users/#{alice.id}"
    assert_not session.reload.active?
    assert refresh.reload.revoked?
    assert token.reload.usable?, "personal tokens stay valid (§6)"
    assert alice.reload.sessions_valid_after
    assert audit("user.signed_out_everywhere")
  end

  test "end one session and sign out one extension of a user" do
    alice = users(:alice)
    row, = Session.start!(user: alice, kind: "home")
    delete "/users/#{alice.id}/sessions/#{row.id}"
    assert_redirected_to "/users/#{alice.id}"
    assert_equal "ended_by_admin", row.reload.end_reason
    assert_equal({ "session_id" => row.id, "kind" => "home", "by" => "admin" }, audit("session.ended").data)

    refresh = create_extension_sign_in(alice)
    delete "/users/#{alice.id}/extensions/#{refresh.id}"
    assert_redirected_to "/users/#{alice.id}"
    assert refresh.reload.revoked?
    assert_equal "admin", audit("oauth.revoked").data["by"]
  end
end
