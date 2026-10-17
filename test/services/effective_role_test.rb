require "test_helper"

# SPECS.md §5.3 as a table: direct grant vs groups, "no access" overrides, highest group role wins
# by the app's order, disabled user, disabled app, and role reordering.
class EffectiveRoleTest < ActiveSupport::TestCase
  setup do
    @irm = apps(:irm)
    @user = User.create!(email: "erin@tourpaq.com", name: "Erin")
  end

  def role(key) = @irm.role(key)
  def group(name) = Group.create!(name: name).tap { GroupMembership.create!(group: _1, user: @user) }
  def grant(subject, key) = Grant.create!(app: @irm, subject: subject, app_role: key && role(key))
  def effective = EffectiveRole.for(@user.reload, @irm.reload)

  test "the table" do
    cases = [
      # [direct grant, [group grants], expected role, expected source]
      [ :none, [], nil, nil ],
      [ :none, [ "viewer" ], "viewer", "G1" ],
      [ :none, [ "viewer", "editor" ], "editor", "G2" ],
      [ :none, [ "editor", "responder", "viewer" ], "editor", "G1" ],
      [ "responder", [], "responder", "direct" ],
      [ "viewer", [ "admin" ], "viewer", "direct" ],        # a direct grant may lower
      [ "admin", [ "viewer" ], "admin", "direct" ],         # or raise
      [ nil, [ "admin", "editor" ], nil, "direct" ]         # or be no access
    ]
    cases.each_with_index do |(direct, group_roles, expected_role, expected_source), i|
      Grant.delete_all
      GroupMembership.where(user: @user).delete_all
      Group.where("name LIKE 'G%'").destroy_all
      grant(@user, direct) unless direct == :none
      group_roles.each_with_index { |key, n| grant(group("G#{n + 1}"), key) }

      result = effective
      assert_same_value expected_role, result.role_key, "case #{i}: #{direct.inspect} + #{group_roles.inspect}"
      assert_same_value expected_source, result.source, "case #{i} source"
      assert_equal !expected_role.nil?, result.access?
    end
  end

  test "equal group roles name the group that sorts first" do
    grant(group("Zulu"), "editor")
    grant(group("Alpha"), "editor")
    assert_equal "Alpha", effective.source
    assert_equal "editor, from Alpha", effective.to_s
  end

  test "a group grant to another app does not count" do
    Grant.create!(app: apps(:kpi), subject: group("G1"), app_role: apps(:kpi).role("admin"))
    assert_not effective.access?
  end

  test "a disabled user has no access, whatever the grants" do
    grant(@user, "admin")
    @user.update!(disabled_at: Time.current)
    assert_nil effective.role
    assert_equal [], EffectiveRole.apps_for(@user)
    assert_not_includes EffectiveRole.members_of(@irm).map(&:user), @user
  end

  test "a disabled app gives no access" do
    grant(@user, "admin")
    @irm.update!(disabled_at: Time.current)
    assert_nil effective.role
    assert_equal [], EffectiveRole.members_of(@irm)
    assert_not_includes EffectiveRole.apps_for(@user).map(&:app), @irm
  end

  test "reordering roles changes which group role is highest" do
    grant(group("G1"), "responder")
    grant(group("G2"), "editor")
    assert_equal "editor", effective.role_key
    @irm.reorder_roles!(%w[viewer editor responder admin])
    assert_equal "responder", effective.role_key
    assert_equal "G1", effective.source
  end

  test "fixtures: alice is responder from RO Dev, mwi admin from DK Tech, bob nothing" do
    assert_equal "responder, from RO Dev", EffectiveRole.for(users(:alice), @irm).to_s
    assert_equal "admin, from DK Tech", EffectiveRole.for(users(:mwi), @irm).to_s
    assert_equal "no access", EffectiveRole.for(users(:bob), @irm).to_s
    assert_not EffectiveRole.for(users(:alice), apps(:kpi)).access?
  end

  test "apps_for lists the apps with access, by name, with role and source" do
    grant(@user, "viewer")
    Grant.create!(app: apps(:kpi), subject: group("G1"), app_role: apps(:kpi).role("editor"))
    result = EffectiveRole.apps_for(@user)
    assert_equal [ "IRM", "KPI" ], result.map { _1.app.name }
    assert_equal [ [ "viewer", "direct" ], [ "editor", "G1" ] ], result.map { [ _1.role_key, _1.source ] }
  end

  test "apps_for leaves out apps where a direct no-access grant overrides a group" do
    grant(group("G1"), "admin")
    grant(@user, nil)
    assert_equal [], EffectiveRole.apps_for(@user)
  end

  test "members_of lists every active user with access and the source" do
    grant(group("G1"), "viewer")
    members = EffectiveRole.members_of(@irm).to_h { [ _1.user.email, _1.to_s ] }
    assert_equal "viewer, from G1", members["erin@tourpaq.com"]
    assert_equal "responder, from RO Dev", members["alice@tourpaq.com"]
    assert_equal "admin, from DK Tech", members["mwi@tourpaq.com"]
    assert_not members.key?("dave@tourpaq.com"), "disabled users are not members"
    assert_not members.key?("bob@tourpaq.com")
  end

  test "members_of respects direct no-access and direct-only users" do
    Grant.create!(app: @irm, subject: users(:alice), app_role: nil)
    grant(@user, "editor")
    members = EffectiveRole.members_of(@irm).to_h { [ _1.user.email, _1.to_s ] }
    assert_not members.key?("alice@tourpaq.com")
    assert_equal "editor, direct", members["erin@tourpaq.com"]
  end

  test "members_of agrees with for(user, app) for every user" do
    grant(group("G1"), "editor")
    grant(users(:bob), "viewer")
    members = EffectiveRole.members_of(@irm).to_h { [ _1.user.id, [ _1.role_key, _1.source ] ] }
    User.find_each do |user|
      single = EffectiveRole.for(user, @irm)
      expected = single.access? ? [ single.role_key, single.source ] : nil
      assert_same_value expected, members[user.id], user.email
    end
  end
end
