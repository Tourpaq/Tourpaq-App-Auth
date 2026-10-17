require "test_helper"

class GrantTest < ActiveSupport::TestCase
  test "the role must be one of the app's" do
    grant = Grant.new(app: apps(:kpi), subject: users(:bob), app_role: apps(:irm).role("viewer"))
    assert_not grant.valid?
    assert_match(/not a role of KPI/, grant.errors.full_messages.join)
  end

  test "no access (no role) is only for users" do
    assert Grant.new(app: apps(:kpi), subject: users(:bob), app_role: nil).valid?
    assert_not Grant.new(app: apps(:kpi), subject: groups(:ro_devops), app_role: nil).valid?
  end

  test "one grant per app and subject" do
    duplicate = Grant.new(app: apps(:irm), subject: groups(:ro_dev), app_role: apps(:irm).role("viewer"))
    assert_not duplicate.valid?
    assert Grant.new(app: apps(:kpi), subject: groups(:ro_dev), app_role: apps(:kpi).role("viewer")).valid?
  end

  test "affected users" do
    assert_equal [ users(:alice), users(:dave_disabled) ].sort_by(&:id), grants(:ro_dev_irm_responder).affected_users.sort_by(&:id)
    assert_equal [ users(:bob) ], Grant.new(app: apps(:kpi), subject: users(:bob)).affected_users.to_a
  end
end
