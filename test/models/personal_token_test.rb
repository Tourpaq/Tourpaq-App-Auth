require "test_helper"

class PersonalTokenTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice) # IRM responder through RO Dev, no KPI access
    @irm = apps(:irm)
  end

  def issue(**options) = PersonalToken.issue!(user: @alice, app: @irm, name: "Claude Code", **options)

  test "issue! returns tpa_<slug>_<43 chars> once and stores the digest and a hint" do
    plain = issue(scope: "read_write", lifetime_days: 30)
    assert_match(/\Atpa_irm_[A-Za-z0-9_-]{43}\z/, plain)
    token = PersonalToken.last
    assert_equal HashedToken.digest(plain), token.token_digest
    assert_equal plain.first(14), token.token_hint
    assert_equal "read_write", token.scope
    assert_in_delta 30.days.from_now, token.expires_at, 5
    event = AuditEvent.last
    assert_equal [ "token.created", @irm ], [ event.action, event.app ]
    assert_not_includes event.data.to_json, plain
  end

  test "the default lifetime is 90 days; only 30, 90 or 365 are allowed" do
    issue
    assert_in_delta 90.days.from_now, PersonalToken.last.expires_at, 5
    assert_raises(ActiveRecord::RecordInvalid) { issue(lifetime_days: 400) }
    assert_raises(ActiveRecord::RecordInvalid) { issue(lifetime_days: 7) }
    assert issue(lifetime_days: 365)
  end

  test "dashes in the slug stay in the prefix" do
    app = App.new(slug: "azure-cost", name: "Azure Cost").tap { _1.roles.build(key: "viewer", position: 1) }.tap(&:save!)
    Grant.create!(app: app, subject: @alice, app_role: app.role("viewer"))
    assert_match(/\Atpa_azure-cost_/, PersonalToken.issue!(user: @alice, app: app, name: "x"))
  end

  test "only for apps the user has access to, and only while active" do
    assert_raises(ActiveRecord::RecordInvalid) { PersonalToken.issue!(user: @alice, app: apps(:kpi), name: "x") }
    assert_raises(ActiveRecord::RecordInvalid) { PersonalToken.issue!(user: users(:dave_disabled), app: @irm, name: "x") }
    assert_raises(ActiveRecord::RecordInvalid) { issue(scope: "admin") }
    assert_raises(ActiveRecord::RecordInvalid) { PersonalToken.issue!(user: @alice, app: @irm, name: " ") }
  end

  test "at most 20 active tokens per user" do
    20.times { issue }
    error = assert_raises(ActiveRecord::RecordInvalid) { issue }
    assert_match(/at most 20/, error.message)
    PersonalToken.last.revoke!(actor: @alice)
    assert issue
  end

  test "find_by_plain finds any state; only tpa_ values are looked up" do
    plain = issue
    assert_equal PersonalToken.last, PersonalToken.find_by_plain(plain)
    assert_nil PersonalToken.find_by_plain("tpa_irm_unknown")
    assert_nil PersonalToken.find_by_plain(PersonalToken.last.token_digest)
    assert_nil PersonalToken.find_by_plain(nil)
    PersonalToken.last.revoke!
    assert PersonalToken.find_by_plain(plain).revoked?
  end

  test "usable?: active, user and app active, and access to the app now" do
    token = PersonalToken.find_by_plain(issue)
    assert token.usable?
    assert_equal "responder", token.effective_role.role_key

    # Access lost and back: refused meanwhile, not deleted (§6).
    no_access = Grant.create!(app: @irm, subject: @alice, app_role: nil)
    assert_not token.reload.usable?
    no_access.destroy
    assert token.reload.usable?

    @irm.update!(disabled_at: Time.current)
    assert_not token.reload.usable?
    @irm.update!(disabled_at: nil)

    travel 91.days
    assert token.reload.expired?
    assert_not token.usable?
  end

  test "revoke! audits once" do
    token = PersonalToken.find_by_plain(issue)
    assert token.revoke!(actor: users(:mwi))
    assert_equal users(:mwi), token.revoked_by
    assert_equal "token.revoked", AuditEvent.last.action
    assert_not token.revoke!
    assert_not token.usable?
  end

  test "expiring_soon and unused scopes" do
    soon = PersonalToken.find_by_plain(issue(lifetime_days: 30))
    later = PersonalToken.find_by_plain(issue(lifetime_days: 365))
    travel 24.days
    assert_includes PersonalToken.expiring_soon, soon
    assert_not_includes PersonalToken.expiring_soon, later
    travel 70.days
    assert_includes PersonalToken.unused, later
    later.touch_used!
    assert_not_includes PersonalToken.unused, later
  end
end
