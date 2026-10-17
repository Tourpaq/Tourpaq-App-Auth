require "test_helper"

# Admin UI for permission-carrying roles and token scopes (SPECS.md §23.2, §23.3, §11.2).
class Admin::PermissionRolesTest < ActionDispatch::IntegrationTest
  setup do
    @dash = create_dashboard_app
    sign_in_admin users(:mwi)
  end

  test "app settings: multiple roles, admin permission and token scopes, audited" do
    post "/apps", params: { app: { slug: "perm", name: "Perm", multiple_roles: "1", admin_permission: "admin:all",
                                   token_scope_list: "public, internal all", role_list: "Team leads\nSupport staff\n" } }
    app = App.find_by!(slug: "perm")
    assert_redirected_to "/apps/#{app.id}"
    assert_equal [ true, "perm_roles", "admin:all", %w[public internal all] ], [ app.multiple_roles?, app.role_claim, app.admin_permission, app.token_scopes ]
    assert_equal [ "Team leads", "Support staff" ], app.role_keys
    assert_equal %w[public internal all], audit("app.created").data["token_scopes"]

    patch "/apps/#{app.id}", params: { app: { name: "Perm", token_scope_list: "read all", admin_permission: "" } }
    assert_equal [ %w[read all], nil ], [ app.reload.token_scopes, app.admin_permission ]
    assert_equal %w[read all], audit("app.updated").data.dig("changes", "token_scopes")

    get "/apps/#{app.id}/edit"
    assert_select "input[name='app[token_scope_list]'][value='read all']"
    assert_select "input[type=checkbox][name='app[multiple_roles]'][checked]"
  end

  test "the app page: roles with permission counts, unknown keys flagged, the catalogue" do
    @dash.role("Support").update!(permissions: %w[module:customers:view old:module:view])
    get "/apps/#{@dash.id}"
    assert_response :success
    assert_select ".attention", /Unknown permissions/
    assert_select ".attention .unknown-permission", "old:module:view"
    assert_select ".pill-bad", "1 unknown"
    assert_select ".pill-warn", "everything (*)"
    assert_select "summary", "5 permissions in 3 groups"
    assert_select "dd.mono", "dashboard_permissions"
    assert_select "dd.mono", "public < all"
    assert_select "a", text: "Higher", count: 0

    get "/"
    assert_select ".attention .unknown-permission", "old:module:view"
  end

  test "the role editor: catalogue checkboxes by group label, unknown keys in red; saving is audited" do
    role = @dash.role("Support")
    role.update!(permissions: %w[module:customers:view old:module:view])
    get "/apps/#{@dash.id}/roles/#{role.id}/edit"
    assert_response :success
    assert_select "fieldset legend", "Modules"
    assert_select "fieldset legend", "Confidential"
    assert_select "fieldset legend", "Administration"
    assert_select "input[type=checkbox][value='module:customers:view'][checked]"
    assert_select "input[type=checkbox][value='module:tasks:view']:not([checked])"
    assert_select "fieldset.unknown label.unknown-permission", /old:module:view/
    assert_select "p.unknown-permission", /old:module:view/
    assert_select "input[type=checkbox][value='*']:not([checked])"

    patch "/apps/#{@dash.id}/roles/#{role.id}", params: { role: { description: "Front line",
                                                                  permissions: [ "", "module:customers:view", "module:tasks:view" ],
                                                                  extra_permissions: "custom:thing:view" } }
    assert_redirected_to "/apps/#{@dash.id}"
    assert_equal %w[custom:thing:view module:customers:view module:tasks:view], role.reload.permissions
    event = audit("app.role_changed")
    assert_equal [ "Support", %w[custom:thing:view module:tasks:view], [ "old:module:view" ], [ "custom:thing:view" ] ],
                 event.data.values_at("key", "permissions_added", "permissions_removed", "unknown")

    patch "/apps/#{@dash.id}/roles/#{role.id}", params: { role: { description: "Front line", permissions: [ "", "bad key" ] } }
    assert_redirected_to "/apps/#{@dash.id}/roles/#{role.id}/edit"
    assert_match "not permission keys", flash[:alert]
  end

  test "a new role is added by name and opens the role editor" do
    post "/apps/#{@dash.id}/roles", params: { role: { key: "Team leads", description: "Leads" } }
    role = @dash.reload.role("Team leads")
    assert_redirected_to "/apps/#{@dash.id}/roles/#{role.id}/edit"
    assert_empty role.permissions
  end

  test "the last-administrator guard in the UI: role edit, grant removal, membership removal, group deletion, disable" do
    grant = grant_dashboard(users(:alice), "Administrators")
    admins = @dash.role("Administrators")

    patch "/apps/#{@dash.id}/roles/#{admins.id}", params: { role: { permissions: [ "", "module:tasks:view" ] } }
    assert_match "needs at least one active user with admin:access:manage", flash[:alert]
    assert_equal [ "*" ], admins.reload.permissions

    delete "/grants/#{grant.id}"
    assert_match "needs at least one active user", flash[:alert]
    assert Grant.exists?(grant.id)

    post "/users/#{users(:alice).id}/disable"
    assert_match "needs at least one active user", flash[:alert]
    assert users(:alice).reload.active?

    GrantChange.remove(grant)
    assert grant.errors.any?
    GroupMembership.create!(group: groups(:ro_devops), user: users(:jjr))
    grant_dashboard(groups(:ro_devops), "Administrators")
    GrantChange.remove(grant.reload)
    assert_not Grant.exists?(grant.id), "jjr holds it through RO DevOps now: #{grant.errors.full_messages}"

    delete "/groups/#{groups(:ro_devops).id}/members/#{users(:jjr).id}"
    assert_match "needs at least one active user", flash[:alert]
    assert groups(:ro_devops).users.reload.include?(users(:jjr))

    delete "/groups/#{groups(:ro_devops).id}"
    assert_redirected_to "/groups/#{groups(:ro_devops).id}"
    assert_match "needs at least one active user", flash[:alert]
    assert Group.exists?(groups(:ro_devops).id)
  end

  test "grants for a user: several roles, no access replaces them, each removable" do
    bob = users(:bob)
    post "/grants", params: { app_id: @dash.id, subject_type: "User", subject_id: bob.id, role: "Support" }
    assert_redirected_to "/users/#{bob.id}"
    assert_equal "Dashboard: Bob Ionescu now holds Support.", flash[:notice]
    post "/grants", params: { app_id: @dash.id, subject_type: "User", subject_id: bob.id, role: "Finance readers" }
    assert_equal [ "Finance readers", "Support" ], EffectiveRole.for(bob, @dash).role_keys
    assert_equal [ nil, [ "Finance readers", "Support" ] ], audit("grant.created").data["users"].first.values_at("before", "after").then { [ nil, _2 ] }

    get "/users/#{bob.id}"
    assert_response :success
    assert_select ".held-roles li", 2
    assert_select "details.permissions summary", "3 permissions"
    assert_select "details.permissions li", /management:finance:view.*from Finance readers \(via direct grant\)/m
    assert_select "select#grant_role_#{@dash.id} option", count: 2 # Administrators and no access
    assert_select "select#grant_role_#{@dash.id} option[value=none]"

    post "/grants", params: { app_id: @dash.id, subject_type: "User", subject_id: bob.id, role: "none" }
    assert_equal [ nil ], Grant.where(app: @dash, subject: bob).pluck(:app_role_id)
    assert_equal [ "Finance readers", "Support" ], audit("grant.created").data["replaced"]
    assert_not EffectiveRole.for(bob, @dash).access?

    post "/grants", params: { app_id: @dash.id, subject_type: "User", subject_id: bob.id, role: "Support" }
    assert_equal [ @dash.role("Support").id ], Grant.where(app: @dash, subject: bob).pluck(:app_role_id), "a role replaces no access"

    grant = Grant.find_by!(app: @dash, subject: bob)
    delete "/grants/#{grant.id}"
    assert_equal "Dashboard: the grant of Support to Bob Ionescu is removed.", flash[:notice]
  end

  test "grants for a group: several roles; members get them with the group as source" do
    group = groups(:ro_dev)
    post "/grants", params: { app_id: @dash.id, subject_type: "Group", subject_id: group.id, role: "Support" }
    post "/grants", params: { app_id: @dash.id, subject_type: "Group", subject_id: group.id, role: "Finance readers" }
    assert_equal 2, Grant.where(app: @dash, subject: group).count
    post "/grants", params: { app_id: @dash.id, subject_type: "Group", subject_id: group.id, role: "none" }
    assert_match "required for a group grant", flash[:alert]

    get "/groups/#{group.id}"
    assert_select ".chip-list .badge", "Support"
    assert_select ".chip-list .badge", "Finance readers"

    get "/apps/#{@dash.id}/members"
    assert_response :success
    row = css_select("tbody tr").detect { _1.text.include?("alice@tourpaq.com") }
    assert_match "Finance readers", row.text
    assert_match "from RO Dev", row.text
    assert_match "3 permissions", row.text
  end

  test "access matrix and CSV: role lists, sources and permissions" do
    grant_dashboard(users(:alice), "Support")
    grant_dashboard(groups(:ro_dev), "Finance readers")
    get "/access"
    assert_response :success
    assert_select "td.matrix-cell .badge-list .badge", "Support"

    get "/access.csv"
    lines = response.body.split("\r\n")
    header = lines.first.split(",")
    assert_includes header, "dashboard permissions"
    alice = lines.detect { _1.start_with?("alice@tourpaq.com") }
    assert_includes alice, "Finance readers; Support"
    assert_includes alice, "Finance readers: RO Dev; Support: direct"
    assert_includes alice, "management:finance:view module:customers:view module:tasks:view"
  end
end

# The index host for a permission app: its card on the index lists the roles; the Tokens page offers the app's scopes.
class PermissionAppHomeTest < ActionDispatch::IntegrationTest
  setup do
    @dash = create_dashboard_app
    grant_dashboard(users(:alice), "Support")
    grant_dashboard(groups(:ro_dev), "Finance readers")
    sign_in_index users(:alice)
  end

  test "the index's card for the app shows the roles list" do
    get "/"
    tile = css_select(".ix-app-card").detect { _1.text.include?("Dashboard") }
    assert_equal [ "Finance readers", "Support" ], tile.css(".held-roles .badge").map(&:text)
    assert_match "from RO Dev", tile.text
  end

  test "the Tokens page offers the chosen app's scopes and creates a scoped token" do
    get "/tokens"
    assert_response :success
    form = css_select("form[data-controller='token-scopes']").first
    scopes = JSON.parse(form["data-token-scopes-scopes-value"])
    assert_equal [ [ "Public", "public" ], [ "All", "all" ] ], scopes[@dash.id.to_s]
    assert_equal [ [ "Read only", "read" ], [ "Read and write", "read_write" ] ], scopes[apps(:irm).id.to_s]

    post "/tokens", params: { personal_token: { app_id: @dash.id, name: "Paperclip", scope: "all", lifetime_days: 90 } }
    assert_response :success
    token = PersonalToken.find_by_plain(css_select(".link-box code").text)
    assert_equal [ @dash, "all" ], [ token.app, token.scope ]
    assert token.token_hint.start_with?("tpa_dashboard_")

    post "/tokens", params: { personal_token: { app_id: @dash.id, name: "Wrong", scope: "read_write", lifetime_days: 90 } }
    assert_response :unprocessable_content
    assert_select ".errors li", /Scope must be one of public or all/
  end

  test "the profile lists the roles with their sources" do
    get "/profile"
    assert_select ".held-roles li", 2
  end
end
