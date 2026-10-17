require "test_helper"

# The per-app last-administrator guard (SPECS.md §23.2): a change that would leave nobody active holding the
# app's admin permission (through "*" or the key) is refused; a catalogue push never counts.
class AppAdminGuardTest < ActiveSupport::TestCase
  setup do
    Current.channel = "admin"
    @app = create_dashboard_app
    @app.add_role!("Access managers", permissions: %w[admin:access:manage])
  end

  teardown { Current.reset }

  test "holders come through * or the key itself" do
    grant_dashboard(users(:alice), "Administrators")
    grant_dashboard(users(:bob), "Access managers")
    grant_dashboard(users(:jjr), "Support")
    assert_equal [ users(:alice), users(:bob) ].sort_by(&:id), AppAdminGuard.holders(@app).sort_by(&:id)
    assert_equal [ @app ], AppAdminGuard.apps_held_by(users(:bob))
    assert_empty AppAdminGuard.apps_held_by(users(:jjr))
  end

  test "removing the last holder's grant is refused; with a second holder it is fine" do
    grant = grant_dashboard(users(:alice), "Administrators")
    assert_no_difference -> { Grant.count } do
      result = GrantChange.remove(grant)
      assert_match "needs at least one active user with admin:access:manage", result.errors.full_messages.to_sentence
    end
    assert_not AuditEvent.exists?(action: "grant.removed")

    grant_dashboard(users(:bob), "Access managers")
    assert GrantChange.remove(grant.reload).errors.empty?
    assert_not Grant.exists?(grant.id)
  end

  test "no access replacing the last holder's roles is refused" do
    grant_dashboard(users(:alice), "Administrators")
    result = GrantChange.set(app: @app, subject: users(:alice), role: nil)
    assert result.errors.any?
    assert EffectiveRole.for(users(:alice), @app).permission?("admin:access:manage")
  end

  test "editing the role's permissions, removing a group member, deleting through a group, disabling the user" do
    group = groups(:ro_devops)
    GroupMembership.create!(group: group, user: users(:bob))
    grant_dashboard(group, "Access managers")
    role = @app.role("Access managers")

    assert_raises(AppAdminGuard::LastAdmin) { AppAdminGuard.protect(@app) { role.update!(permissions: %w[module:tasks:view]) } }
    assert_equal %w[admin:access:manage], role.reload.permissions

    assert_raises(AppAdminGuard::LastAdmin) { AppAdminGuard.protect([ @app ]) { GroupMembership.find_by!(group: group, user: users(:bob)).destroy! } }
    assert group.users.reload.include?(users(:bob))

    error = assert_raises(ActiveRecord::RecordInvalid) { users(:bob).disable!(actor: users(:mwi)) }
    assert_match "Dashboard needs at least one active user", error.message
    assert users(:bob).reload.active?
    assert_not AuditEvent.exists?(action: "user.disabled", subject: users(:bob))
  end

  test "a catalogue push that drops the admin key does not count: the key is still sent" do
    grant_dashboard(users(:alice), "Access managers")
    CataloguePush.call(@app, [ { "key" => "module:tasks:view" } ])
    assert EffectiveRole.for(users(:alice), @app.reload).permission?("admin:access:manage")
    assert_includes @app.unknown_permissions[@app.role("Access managers")], "admin:access:manage"
  end

  test "an app nobody administers yet is not guarded, nor one without an admin permission" do
    grant = grant_dashboard(users(:alice), "Support")
    assert GrantChange.remove(grant).errors.empty?
    @app.update!(admin_permission: nil)
    grant = grant_dashboard(users(:alice), "Administrators")
    assert GrantChange.remove(grant).errors.empty?
  end
end
