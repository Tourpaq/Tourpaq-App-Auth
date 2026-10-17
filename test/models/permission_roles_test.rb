require "test_helper"

# Permission-carrying roles and per-app token scopes on the models (SPECS.md §23.2, §23.3).
class PermissionRolesTest < ActiveSupport::TestCase
  setup { @app = create_dashboard_app }

  test "a multiple-roles app: role claim default <slug>_roles, the permissions claim, no roles needed" do
    app = App.create!(slug: "perm-app", name: "Perm", multiple_roles: true)
    assert_equal [ "perm_app_roles", "perm_app_permissions" ], [ app.role_claim, app.permissions_claim ]
    assert_empty app.roles
    assert_nil apps(:irm).permissions_claim
    assert_not App.new(slug: "plain", name: "Plain").valid?, "a single-role app still needs a role"
  end

  test "the role claim may not be the permissions claim" do
    app = App.new(slug: "x", name: "X", multiple_roles: true, role_claim: "x_permissions")
    assert_not app.valid?
    assert_match "must differ", app.errors.full_messages.to_sentence
  end

  test "role names keep case and spaces in a multiple-roles app; single-role keys stay lowercase" do
    role = @app.add_role!("  Team   leads ")
    assert_equal "Team leads", role.key
    assert_equal role, @app.reload.role("team LEADS")
    assert_not @app.roles.build(key: "team leads", position: 99).valid?, "unique without regard to case"
    assert_equal "owner", apps(:kpi).add_role!("Owner").key
    assert_not apps(:kpi).roles.build(key: "Team leads", position: 99).valid?
  end

  test "permissions: sorted, unique, * kept, keys checked; only for multiple-roles apps" do
    role = @app.role("Support")
    role.update!(permissions: [ " module:tasks:view", "*", "module:tasks:view", "", "module:customers:view" ])
    assert_equal %w[* module:customers:view module:tasks:view], role.permissions
    assert role.wildcard?
    assert role.grants_permission?("anything:at:all")
    role.permissions = [ "not a key", "ok:key" ]
    assert_not role.valid?
    assert_match "not permission keys: not a key", role.errors.full_messages.to_sentence
    viewer = apps(:irm).role("viewer")
    viewer.permissions = [ "x:y:z" ]
    assert_not viewer.valid?
  end

  test "unknown permissions: keys missing from the pushed catalogue, never *" do
    role = @app.role("Support")
    role.update!(permissions: %w[module:customers:view old:module:view])
    assert_equal [ "old:module:view" ], role.unknown_permissions
    assert_equal({ role => [ "old:module:view" ] }, @app.reload.unknown_permissions)
    assert_empty @app.role("Administrators").unknown_permissions

    fresh = App.create!(slug: "fresh", name: "Fresh", multiple_roles: true)
    fresh.add_role!("R", permissions: %w[a:b:c])
    assert_empty fresh.unknown_permissions, "nothing to compare with before the first push"
  end

  test "grants: several roles per subject in a multiple-roles app, one per role" do
    user = users(:bob)
    Grant.create!(app: @app, subject: user, app_role: @app.role("Support"))
    assert Grant.new(app: @app, subject: user, app_role: @app.role("Finance readers")).valid?
    assert_not Grant.new(app: @app, subject: user, app_role: @app.role("Support")).valid?
    Grant.create!(app: @app, subject: groups(:ro_dev), app_role: @app.role("Support"))
    assert Grant.new(app: @app, subject: groups(:ro_dev), app_role: @app.role("Administrators")).valid?
  end

  test "grants: a user's no access excludes their other grants in that app, both ways" do
    user = users(:bob)
    Grant.create!(app: @app, subject: user, app_role: @app.role("Support"))
    no_access = Grant.new(app: @app, subject: user, app_role: nil)
    assert_not no_access.valid?
    assert_match "No access excludes", no_access.errors.full_messages.to_sentence

    other = users(:carol)
    Grant.create!(app: @app, subject: other, app_role: nil)
    assert_not Grant.new(app: @app, subject: other, app_role: @app.role("Support")).valid?
    assert_not Grant.new(app: @app, subject: other, app_role: nil).valid?
  end

  test "single-role apps keep one grant per subject" do
    assert_not Grant.new(app: apps(:irm), subject: groups(:ro_dev), app_role: apps(:irm).role("viewer")).valid?
  end

  test "multiple roles cannot be turned off while somebody holds several roles" do
    Grant.create!(app: @app, subject: users(:bob), app_role: @app.role("Support"))
    Grant.create!(app: @app, subject: users(:bob), app_role: @app.role("Finance readers"))
    assert_not @app.update(multiple_roles: false)
    assert_match "several roles", @app.errors.full_messages.to_sentence
  end

  test "token scopes: ordered, valid names, default read < read_write; a scope in use cannot go" do
    assert_equal %w[read read_write], apps(:irm).token_scopes
    assert_equal [ "public", "all" ], [ @app.lowest_token_scope, @app.highest_token_scope ]
    assert_not @app.update(token_scope_list: "public bad-scope!")
    @app.reload
    assert_not @app.update(token_scopes: %w[public public])
    @app.reload

    grant_dashboard(users(:alice), "Support")
    PersonalToken.issue!(user: users(:alice), app: @app, name: "MCP", scope: "all")
    assert_not @app.reload.update(token_scope_list: "public")
    assert_match "still in use by active tokens: all", @app.errors.full_messages.to_sentence
    assert @app.reload.update(token_scope_list: "public internal all")
  end

  test "personal tokens take the app's scopes; the lowest by default" do
    grant_dashboard(users(:alice), "Support")
    token = PersonalToken.find_by_plain(PersonalToken.issue!(user: users(:alice), app: @app, name: "Default"))
    assert_equal "public", token.scope
    assert_raises(ActiveRecord::RecordInvalid) { PersonalToken.issue!(user: users(:alice), app: @app, name: "X", scope: "read_write") }
    assert_raises(ActiveRecord::RecordInvalid) { PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "X", scope: "all") }
    assert PersonalToken.find_by_plain(PersonalToken.issue!(user: users(:alice), app: @app, name: "All", scope: "all")).highest_scope?
  end
end
