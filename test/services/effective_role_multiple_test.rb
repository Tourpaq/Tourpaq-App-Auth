require "test_helper"

# SPECS.md §23.2: in a multiple-roles app the effective roles are the union of the direct grants and the groups'
# grants; permissions are the union of those roles' permissions; a direct "no access" overrides everything;
# a disabled user or app has nothing. Single-role apps are unchanged (effective_role_test.rb).
class EffectiveRoleMultipleTest < ActiveSupport::TestCase
  setup do
    @app = create_dashboard_app
    @user = User.create!(email: "erin@tourpaq.com", name: "Erin")
  end

  def group(name) = Group.create!(name: name).tap { GroupMembership.create!(group: _1, user: @user) }
  def effective = EffectiveRole.for(@user.reload, @app.reload)

  test "the table: union of direct and group roles, no access overrides" do
    cases = [
      # [direct roles (nil = no access), { group => roles }, expected roles, expected permissions]
      [ [], {}, [], [] ],
      [ [ "Support" ], {}, [ "Support" ], %w[module:customers:view module:tasks:view] ],
      [ [], { "G1" => [ "Finance readers" ] }, [ "Finance readers" ], %w[management:finance:view module:customers:view] ],
      [ [ "Support" ], { "G1" => [ "Finance readers" ] }, [ "Finance readers", "Support" ],
        %w[management:finance:view module:customers:view module:tasks:view] ],
      [ [], { "G1" => [ "Support" ], "G2" => [ "Support", "Administrators" ] }, [ "Administrators", "Support" ],
        %w[* module:customers:view module:tasks:view] ],
      [ nil, { "G1" => [ "Administrators" ] }, [], [] ]
    ]
    cases.each_with_index do |(direct, groups, roles, permissions), i|
      Grant.delete_all
      GroupMembership.where(user: @user).delete_all
      Group.where("name LIKE 'G%'").destroy_all
      if direct.nil?
        Grant.create!(app: @app, subject: @user, app_role: nil)
      else
        direct.each { Grant.create!(app: @app, subject: @user, app_role: @app.role(_1)) }
      end
      groups.each { |name, keys| g = group(name); keys.each { Grant.create!(app: @app, subject: g, app_role: @app.role(_1)) } }

      result = effective
      assert_equal roles, result.role_keys, "case #{i} roles"
      assert_equal permissions, result.permissions, "case #{i} permissions"
      assert_equal roles.any?, result.access?, "case #{i} access"
      assert_nil result.role, "the single role stays nil"
      assert_nil result.role_key
    end
  end

  test "sources: direct and every group, by name; to_s and audit value" do
    g2 = group("Zulu")
    g1 = group("Alpha")
    Grant.create!(app: @app, subject: @user, app_role: @app.role("Support"))
    Grant.create!(app: @app, subject: g2, app_role: @app.role("Support"))
    Grant.create!(app: @app, subject: g1, app_role: @app.role("Support"))
    Grant.create!(app: @app, subject: g1, app_role: @app.role("Finance readers"))
    result = effective
    assert_equal [ [ "Finance readers", [ "Alpha" ] ], [ "Support", [ "direct", "Alpha", "Zulu" ] ] ], result.held.map { [ _1.key, _1.sources ] }
    assert_equal "Finance readers (from Alpha), Support (direct, from Alpha, from Zulu)", result.to_s
    assert_equal [ "Finance readers", "Support" ], result.audit_value
    sources = result.permission_sources.to_h { |key, held| [ key, held.map(&:key) ] }
    assert_equal [ "Finance readers", "Support" ], sources["module:customers:view"]
    assert_equal [ "Finance readers" ], sources["management:finance:view"]
    assert_equal result.held, EffectiveRole.roles_for(@user, @app)
    assert_equal result.permission_sources, EffectiveRole.permissions_for(@user, @app)
    assert result.permission?("module:tasks:view")
    assert_not result.permission?("admin:access:manage")
  end

  test "no access (direct) reads as such" do
    Grant.create!(app: @app, subject: @user, app_role: nil)
    group("G1").then { Grant.create!(app: @app, subject: _1, app_role: @app.role("Support")) }
    assert_equal "no access (direct)", effective.to_s
    assert_nil effective.audit_value
  end

  test "disabled user or disabled app: nothing" do
    Grant.create!(app: @app, subject: @user, app_role: @app.role("Administrators"))
    assert effective.permission?("anything")
    @app.update!(disabled_at: Time.current)
    assert_not effective.access?
    assert_empty EffectiveRole.members_of(@app)
    @app.update!(disabled_at: nil)
    @user.update!(disabled_at: Time.current)
    assert_not effective.access?
    assert_empty effective.permissions
    assert_not_includes EffectiveRole.members_of(@app).map(&:user), @user
  end

  test "members_of and apps_for agree with for(user, app)" do
    g = group("G1")
    Grant.create!(app: @app, subject: g, app_role: @app.role("Support"))
    Grant.create!(app: @app, subject: @user, app_role: @app.role("Finance readers"))
    Grant.create!(app: @app, subject: users(:alice), app_role: @app.role("Administrators"))
    Grant.create!(app: @app, subject: groups(:ro_dev), app_role: @app.role("Support"))
    Grant.create!(app: @app, subject: users(:bob), app_role: nil)
    members = EffectiveRole.members_of(@app).to_h { [ _1.user.id, [ _1.role_keys, _1.permissions, _1.held.map(&:sources) ] ] }
    User.find_each do |user|
      single = EffectiveRole.for(user, @app)
      expected = single.access? ? [ single.role_keys, single.permissions, single.held.map(&:sources) ] : nil
      assert_same_value expected, members[user.id], user.email
    end
    assert_equal [ "Finance readers", "Support" ], EffectiveRole.apps_for(@user).detect { _1.app == @app }.role_keys
    assert_equal [ "Administrators", "Support" ], members[users(:alice).id].first, "alice: direct and from RO Dev"
  end

  test "single-role apps are unchanged: one role, no permissions" do
    result = EffectiveRole.for(users(:alice), apps(:irm))
    assert_equal [ "responder", [ "responder" ], [], "responder" ], [ result.role_key, result.role_keys, result.permissions, result.audit_value ]
    assert_not result.multiple?
  end
end
