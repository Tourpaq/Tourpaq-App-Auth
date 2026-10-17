require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "a new user gets a random UUID sub that never changes" do
    user = User.create!(email: "New.Person@Tourpaq.com ")
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, user.sub)
    assert_equal "new.person@tourpaq.com", user.email
    original = user.sub
    user.update!(name: "New")
    assert_equal original, user.reload.sub
    assert_raises(ActiveRecord::ActiveRecordError) { user.update_column(:sub, SecureRandom.uuid) }
  end

  test "email is unique case-insensitively and must look like an address" do
    assert_not User.new(email: "MWI@tourpaq.com").valid?
    assert_not User.new(email: "not an email").valid?
  end

  test "entra oid + tid are unique together" do
    user = User.new(email: "x@tourpaq.com", entra_oid: users(:mwi).entra_oid, entra_tid: users(:mwi).entra_tid)
    assert_not user.valid?
    user.entra_tid = "another-tenant"
    assert user.valid?
  end

  test "pending: active non-admins with no direct role grant and no group" do
    pending = User.pending.to_a
    assert_includes pending, users(:bob)
    assert_includes pending, users(:carol)
    assert_not_includes pending, users(:alice) # in RO Dev
    assert_not_includes pending, users(:mwi)   # admin
    assert_not_includes pending, users(:dave_disabled)
    Grant.create!(app: apps(:kpi), subject: users(:bob), app_role: apps(:kpi).role("viewer"))
    assert_not users(:bob).pending?
  end

  test "disable! ends home and admin sessions, revokes extension tokens and audits" do
    user = users(:alice)
    home, = Session.start!(user: user, kind: "home")
    admin, = Session.start!(user: user, kind: "admin")
    token = OauthToken.create!(client: clients(:irm_extension), user: user, kind: "refresh", token_digest: "d1", chain_id: "c1", expires_at: 1.day.from_now)

    assert user.disable!(actor: users(:mwi))
    assert user.disabled?
    assert_not_nil home.reload.ended_at
    assert_equal "disabled", admin.reload.end_reason
    assert token.reload.revoked?
    event = AuditEvent.last
    assert_equal [ "user.disabled", user, users(:mwi) ], [ event.action, event.subject, event.actor ]
    assert_not user.disable!, "already disabled"
  end

  test "disable! leaves personal tokens in place; they are refused while disabled" do
    user = users(:alice)
    plain = PersonalToken.issue!(user: user, app: apps(:irm), name: "MCP")
    user.disable!
    token = PersonalToken.find_by_plain(plain)
    assert_not token.revoked?
    assert_not token.usable?
    user.enable!
    assert token.reload.usable?
  end

  test "the last active admin can be neither disabled nor demoted" do
    users(:jjr).update!(admin: false)
    mwi = users(:mwi)
    assert User.last_active_admin?(mwi)
    error = assert_raises(ActiveRecord::RecordInvalid) { mwi.disable! }
    assert_match(/last active admin/, error.message)
    assert_raises(ActiveRecord::RecordInvalid) { mwi.reload.remove_admin! }
    assert mwi.reload.admin? && mwi.active?

    users(:jjr).make_admin!
    assert mwi.remove_admin!
    assert_not mwi.reload.admin?
  end

  test "a disabled admin does not count as the other active admin" do
    users(:jjr).update!(disabled_at: Time.current)
    assert User.last_active_admin?(users(:mwi))
  end

  test "make_admin! and remove_admin! audit, and removing admin ends admin sessions" do
    alice = users(:alice)
    assert alice.make_admin!(actor: users(:mwi))
    assert_equal "user.admin_granted", AuditEvent.last.action
    admin_session, = Session.start!(user: alice, kind: "admin")
    home_session, = Session.start!(user: alice, kind: "home")
    assert alice.remove_admin!(actor: users(:mwi))
    assert_equal "user.admin_revoked", AuditEvent.last.action
    assert_equal "not_admin", admin_session.reload.end_reason
    assert home_session.reload.active?
  end

  test "sign_out_everywhere! ends sessions, revokes extension tokens, bumps sessions_valid_after, keeps personal tokens" do
    user = users(:alice)
    session, = Session.start!(user: user)
    access = OauthToken.create!(client: clients(:irm_extension), user: user, kind: "access", token_digest: "d2", chain_id: "c2", expires_at: 1.hour.from_now)
    plain = PersonalToken.issue!(user: user, app: apps(:irm), name: "MCP")

    freeze_time do
      user.sign_out_everywhere!(actor: users(:mwi))
      assert_equal Time.current, user.reload.sessions_valid_after
    end
    assert_equal "signed_out_everywhere", session.reload.end_reason
    assert access.reload.revoked?
    assert PersonalToken.find_by_plain(plain).usable?
    assert_equal "user.signed_out_everywhere", AuditEvent.last.action
  end

  test "enable! audits" do
    user = users(:dave_disabled)
    assert user.enable!
    assert user.active?
    assert_equal "user.enabled", AuditEvent.last.action
  end
end
