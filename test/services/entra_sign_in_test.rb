require "test_helper"

# SPECS.md §3.2: who the user is.
class EntraSignInTest < ActiveSupport::TestCase
  def sign_in(email:, **claims) = EntraSignIn.call(FakeIdentity.auth_hash(email: email, **claims))

  test "finds a bound user by oid + tid and refreshes name, email and UPN" do
    mwi = users(:mwi)
    result = sign_in(email: "mogens@tourpaq.com", oid: mwi.entra_oid, name: "Mogens W", upn: "mogens@tourpaq.com")
    assert result.success?
    assert_equal mwi, result.user
    mwi.reload
    assert_equal [ "mogens@tourpaq.com", "Mogens W", "mogens@tourpaq.com" ], [ mwi.email, mwi.name, mwi.upn ]
    assert_in_delta Time.current, mwi.last_login_at, 2
  end

  test "the key is the oid, not the email: same email with another oid is not that user" do
    result = sign_in(email: "mwi@tourpaq.com", oid: SecureRandom.uuid)
    assert_equal :email_in_use, result.error
    assert_equal "auth.login_refused", AuditEvent.last.action
  end

  test "a pre-created user is bound once, by email, case-insensitively" do
    carol = users(:carol)
    oid = SecureRandom.uuid
    result = sign_in(email: "Carol@Contractor.example", oid: oid, name: "Carol Contractor")
    assert_equal carol, result.user
    assert_equal [ oid, entra_tenant_id ], [ carol.reload.entra_oid, carol.entra_tid ]
    assert_equal "Carol Contractor", carol.name
    assert_equal "user.bound", AuditEvent.where(subject: carol).order(:id).first.action

    # Once bound, only the oid counts: another account with the same email is not Carol.
    other = sign_in(email: "carol@contractor.example", oid: SecureRandom.uuid)
    assert_not other.success?
    assert_equal :email_in_use, other.error
    assert_equal carol, sign_in(email: "carol@contractor.example", oid: oid).user
    assert_equal 1, AuditEvent.where(action: "user.bound").count
  end

  test "a first sign-in creates a pending user with a new sub" do
    assert_difference -> { User.count } do
      @result = sign_in(email: "New.Colleague@tourpaq.com", name: "New Colleague")
    end
    user = @result.user
    assert_equal "new.colleague@tourpaq.com", user.email
    assert_equal FakeIdentity.oid_for("New.Colleague@tourpaq.com"), user.entra_oid
    assert user.pending?
    assert_not user.admin?
    assert_equal "user.created", AuditEvent.where(subject: user).first.action
  end

  test "a missing email claim falls back to preferred_username" do
    result = sign_in(email: nil, upn: "upn.only@tourpaq.com", oid: SecureRandom.uuid)
    assert result.success?
    assert_equal "upn.only@tourpaq.com", result.user.email
  end

  test "no email at all is refused" do
    result = sign_in(email: nil, upn: nil, oid: SecureRandom.uuid)
    assert_equal :missing_email, result.error
  end

  test "the wrong tenant is refused and audited" do
    assert_no_difference -> { User.count } do
      @result = sign_in(email: "someone@other.example", tid: SecureRandom.uuid)
    end
    assert_equal :wrong_tenant, @result.error
    event = AuditEvent.last
    assert_equal [ "auth.login_refused", "wrong_tenant" ], [ event.action, event.data["reason"] ]
  end

  test "a missing oid is refused" do
    assert_equal :missing_identity, sign_in(email: "x@tourpaq.com", oid: "").error
  end

  test "a disabled user is refused, bound or pre-created" do
    assert_equal :disabled, sign_in(email: "dave@tourpaq.com").error
    users(:carol).update!(disabled_at: Time.current)
    result = sign_in(email: "carol@contractor.example")
    assert_equal :disabled, result.error
    assert_nil users(:carol).reload.entra_oid, "not bound while disabled"
  end

  test "an email change that collides with another user keeps the old email" do
    result = sign_in(email: "alice@tourpaq.com", oid: users(:bob).entra_oid)
    assert_equal users(:bob), result.user
    assert_equal "bob@tourpaq.com", users(:bob).reload.email
  end
end
