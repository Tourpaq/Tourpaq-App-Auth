require "test_helper"

class GrantChangeTest < ActiveSupport::TestCase
  setup { Current.channel = "admin" }
  teardown { Current.reset }

  test "creating, changing and removing a group grant audits every active member's before and after" do
    grant = GrantChange.set(app: apps(:kpi), subject: groups(:ro_dev), role: app_roles(:kpi_editor))
    assert grant.persisted?
    event = AuditEvent.last
    assert_equal [ "grant.created", groups(:ro_dev), apps(:kpi) ], [ event.action, event.subject, event.app ]
    assert_equal "Group RO Dev", event.data["subject"]
    assert_equal [ users(:alice).id ], event.data["users"].map { _1["user_id"] }, "dave is disabled"

    GrantChange.set(app: apps(:kpi), subject: groups(:ro_dev), role: app_roles(:kpi_admin))
    event = AuditEvent.last
    assert_equal "grant.changed", event.action
    assert_equal [ "editor", "admin" ], event.data.values_at("role_before", "role_after")

    GrantChange.remove(grant.reload)
    assert_equal "grant.removed", AuditEvent.last.action
    assert_equal [ "admin", nil ], AuditEvent.last.data["users"].first.values_at("before", "after")
  end

  test "an invalid grant changes and records nothing" do
    assert_no_difference [ "Grant.count", "AuditEvent.count" ] do
      grant = GrantChange.set(app: apps(:kpi), subject: groups(:ro_dev), role: nil)
      assert grant.errors[:app_role].any?
    end
  end
end

class RoleReorderTest < ActiveSupport::TestCase
  test "the preview changes nothing; the same order shows nobody" do
    assert_empty RoleReorder.preview(apps(:irm), apps(:irm).role_keys)
    GroupMembership.create!(group: groups(:ro_devops), user: users(:alice))
    Grant.create!(app: apps(:irm), subject: groups(:ro_devops), app_role: app_roles(:irm_viewer))
    changes = RoleReorder.preview(apps(:irm), %w[responder viewer editor admin])
    assert_equal [ [ users(:alice), "responder", "viewer" ] ], changes.map { [ _1.user, _1.before, _1.after ] }
    assert_equal %w[viewer responder editor admin], apps(:irm).reload.role_keys
  end
end

class CsvLineTest < ActiveSupport::TestCase
  test "quotes, escapes and defuses formulas" do
    assert_equal "a,b\r\n", CsvLine.call(%w[a b])
    assert_equal "\"x, y\",\"say \"\"hi\"\"\",\r\n", CsvLine.call([ "x, y", 'say "hi"', nil ])
    assert_equal "'=1+1,'+x,'-x,'@x,ok\r\n", CsvLine.call(%w[=1+1 +x -x @x ok])
  end
end
