require "test_helper"

class AppTest < ActiveSupport::TestCase
  def new_app(slug, roles: %w[viewer admin], **attrs)
    App.new(slug: slug, name: slug.titleize, **attrs).tap do |app|
      roles.each_with_index { |key, i| app.roles.build(key: key, position: i + 1) }
    end
  end

  test "role_claim cannot be a standard claim name, which it would overwrite in ID tokens and userinfo" do
    %w[sub iss aud nonce email name preferred_username sessions_valid_after auth_time].each do |claim|
      app = new_app("x-#{claim.tr('_', '-')}", role_claim: claim)
      assert_not app.valid?, claim
      assert_includes app.errors[:role_claim].join, "standard claim", claim
    end
    assert new_app("x", role_claim: "x_role").valid?
  end

  test "role_claim defaults to <slug>_role with dashes as underscores" do
    assert_equal "azure_cost_role", new_app("azure-cost").tap(&:save!).role_claim
    assert_equal "logs_role", new_app("logs").tap(&:save!).role_claim
    assert_equal "custom", new_app("x", role_claim: "custom").tap(&:save!).role_claim
  end

  test "slug: lowercase letters, digits and dashes, unique, never changed" do
    assert_not new_app("Bad Slug").valid?
    assert_not new_app("irm").valid?
    assert_equal "upper", new_app("UPPER").tap(&:valid?).slug
    app = new_app("fixed").tap(&:save!)
    assert_raises(ActiveRecord::ActiveRecordError) { app.update_column(:slug, "other") }
  end

  test "an app needs at least one role" do
    app = new_app("empty", roles: [])
    assert_not app.valid?
    assert_includes app.errors[:roles], "need at least one role"
  end

  test "roles are ordered lowest first, with ranks" do
    irm = apps(:irm)
    assert_equal %w[viewer responder editor admin], irm.role_keys
    assert_equal 0, irm.rank("viewer")
    assert_equal 3, irm.rank(irm.role("admin"))
    assert_nil irm.rank("owner")
    assert_equal "viewer", irm.lowest_role.key
    assert_equal "admin", irm.highest_role.key
  end

  test "add_role! appends at the top" do
    role = apps(:kpi).add_role!("owner", description: "Owns it")
    assert_equal 4, role.position
    assert_equal "owner", apps(:kpi).reload.highest_role.key
  end

  test "reorder_roles! needs every role exactly once and keeps positions unique" do
    irm = apps(:irm)
    irm.reorder_roles!(%w[viewer editor responder admin])
    assert_equal %w[viewer editor responder admin], irm.reload.role_keys
    assert_equal [ 1, 2, 3, 4 ], irm.roles.map(&:position)
    assert_raises(ArgumentError) { irm.reorder_roles!(%w[viewer admin]) }
  end

  test "a role still used by a grant cannot be removed" do
    role = apps(:irm).role("responder")
    assert role.in_use?
    assert_not role.destroy
    assert AppRole.exists?(role.id)
    assert apps(:irm).role("viewer").destroy
  end

  test "role keys are unique per app and lowercase" do
    assert_not apps(:irm).roles.build(key: "viewer", position: 9).valid?
    assert_equal "owner", AppRole.new(app: apps(:irm), key: " Owner ").tap(&:valid?).key
  end
end
