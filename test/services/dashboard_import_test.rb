require "test_helper"
require "rake"

# The Dashboard import (SPECS.md §23.5 step 2) against test/fixtures/files/dashboard_export.json, which has a case
# for every rule: matched by oid, bound by email, created bound, created pre-created, skipped without membership,
# inactive (with and without oid), an email that belongs to another Entra account, matched by email without oid,
# a user with "no access" in the auth app, an invalid email; the Administrators group, a role that exists with
# other permissions, a group with a key the catalogue does not know; one live token.
class DashboardImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  OIDS = { alice: "aaaaaaaa-0000-4000-8000-000000000001", carol: "cccccccc-0000-4000-8000-000000000002",
           new_bound: "eeeeeeee-0000-4000-8000-000000000003", left: "ffffffff-0000-4000-8000-000000000007",
           kim: "abababab-0000-4000-8000-000000000010" }.freeze

  setup do
    Current.channel = "console"
    @dash = create_dashboard_app(roles: false)
    @dash.add_role!("Support", description: "Old text", permissions: %w[module:customers:view])
    @tenant = Rails.configuration.x.auth.entra_tenant_id
    users(:alice).update!(entra_oid: OIDS[:alice])
    @kim = User.create!(email: "kim@tourpaq.com", name: "Kim", entra_oid: OIDS[:kim], entra_tid: @tenant)
    Grant.create!(app: @dash, subject: @kim, app_role: nil)
    @json = file_fixture("dashboard_export.json").read
  end

  teardown { Current.reset }

  def import(apply:, json: @json, force: false) = DashboardImport.call(json, apply: apply, force: force, source: "dashboard_export.json")
  def counts = [ User, Grant, AppRole, AuditEvent ].map(&:count)
  def subject_lines(report, action, kind) = report.lines.select { _1.action == action && _1.kind == kind }.map(&:subject)

  test "a dry run reports everything and changes nothing" do
    before = counts
    report = import(apply: false)
    assert_equal before, counts
    assert_not report.applied?
    assert_nil User.find_by_email("new.bound@tourpaq.com")
    assert_equal %w[module:customers:view], @dash.role("Support").reload.permissions
    text = report.to_s
    assert_match "DRY RUN, nothing was changed", text
    assert_match "Run again with APPLY=1", text
    assert_match(/create\s+user\s+new\.bound@tourpaq\.com\s+created bound/, text)
    assert_equal [ "Administrators", "Finance readers", "Old group" ], subject_lines(report, "create", "role").sort
  end

  test "applied: every rule" do
    report = import(apply: true)
    assert report.applied?

    # Roles: same names, descriptions and permissions; Administrators → "*"; an existing role brought in line.
    assert_equal [ "*" ], @dash.role("Administrators").permissions
    assert_equal [ "Customers and tasks", %w[module:customers:view module:tasks:view] ], [ @dash.role("Support").description, @dash.role("Support").permissions ]
    assert_equal [ "Support" ], subject_lines(report, "change", "role")
    assert_equal %w[management:finance:view module:customers:view], @dash.role("Finance readers").permissions
    assert_equal [ "old:module:view" ], @dash.role("Old group").unknown_permissions, "kept and flagged, not dropped"

    # Users.
    assert_equal [ "alice@tourpaq.com", "jjr@tourpaq.com", "kim@tourpaq.com" ], subject_lines(report, "ok", "user").sort
    carol = users(:carol).reload
    assert_equal [ OIDS[:carol], @tenant ], [ carol.entra_oid, carol.entra_tid ]
    assert_equal [ "carol@contractor.example" ], subject_lines(report, "change", "user")
    created = User.find_by_email!("new.bound@tourpaq.com")
    assert_equal [ OIDS[:new_bound], @tenant, "New Bound" ], [ created.entra_oid, created.entra_tid, created.name ]
    pre = User.find_by_email!("yt.member@tourpaq.com")
    assert_not pre.bound?
    left = User.find_by_email!("left@tourpaq.com")
    assert left.active?, "inactive in the Dashboard is not disabled here"
    assert_empty Grant.where(subject: left)
    assert_nil User.find_by_email("yt.nogroup@tourpaq.com")
    assert_nil User.find_by_email("yt.inactive@tourpaq.com")
    skipped = report.lines.select { _1.action == "skip" && _1.kind == "user" }.to_h { [ _1.subject, _1.detail ] }
    assert_equal "never signed in and in no group", skipped["yt.nogroup@tourpaq.com"]
    assert_equal "inactive and never signed in", skipped["yt.inactive@tourpaq.com"]
    assert_match "another Entra account", skipped["bob@tourpaq.com"]
    assert_equal "no valid email", skipped["not an email"]
    assert_not_equal OIDS[:alice], users(:bob).reload.entra_oid

    # Memberships → direct grants.
    expected = { "alice@tourpaq.com" => [ "Administrators", "Support" ], "carol@contractor.example" => [ "Support" ],
                 "new.bound@tourpaq.com" => [ "Finance readers" ], "yt.member@tourpaq.com" => [ "Support" ],
                 "jjr@tourpaq.com" => [ "Finance readers" ] }
    expected.each do |email, roles|
      assert_equal roles, EffectiveRole.for(User.find_by_email!(email), @dash).role_keys, email
      assert Grant.where(app: @dash, subject: User.find_by_email!(email)).all? { _1.subject_type == "User" }
    end
    assert_equal [ nil ], Grant.where(app: @dash, subject: @kim).pluck(:app_role_id), "a no-access grant in the auth app stays"
    grant_skips = report.lines.select { _1.action == "skip" && _1.kind == "grant" }.map(&:detail)
    assert_includes grant_skips, "inactive in the Dashboard"
    assert_includes grant_skips, "the user was not imported"
    assert_includes report.lines.map(&:subject), "yt.inactive@tourpaq.com → Support"
    assert grant_skips.any? { _1.include?("no access to Dashboard") }

    # The check: bob and kim differ (both visible in the report), everyone else matches.
    assert_equal [ "bob@tourpaq.com", "kim@tourpaq.com" ], report.differences.map(&:subject).sort
    assert_match "Check: 2 differences", report.to_s
    assert_match "Paperclip", report.to_s

    # Audited: each change, and the import as a whole.
    event = AuditEvent.where(action: "import.dashboard").last
    assert_equal [ @dash, nil, "console", true, 2 ], [ event.subject, event.actor, event.channel, event.data["applied"], event.data["differences"] ]
    assert AuditEvent.exists?(action: "user.bound", subject: carol)
    assert AuditEvent.exists?(action: "user.created", subject: created)
    assert AuditEvent.exists?(action: "user.precreated", subject: pre)
    assert_equal 6, AuditEvent.where(action: "grant.created", app: @dash).count
    assert_equal 3, AuditEvent.where(action: "app.role_added", app: @dash).count
  end

  test "idempotent: running it again (forced) changes nothing" do
    import(apply: true)
    before = counts
    roles = @dash.roles.reload.map { [ _1.key, _1.description, _1.permissions ] }
    report = import(apply: true, force: true)
    assert_empty report.changes, report.to_s
    assert_equal before.first(3), counts.first(3)
    assert_equal 1, AuditEvent.count - before.last, "only the import.dashboard event"
    assert_equal roles, @dash.roles.reload.map { [ _1.key, _1.description, _1.permissions ] }
    assert_match "roles  0 created, 0 changed, 4 unchanged", report.to_s
    assert_match "users  0 created, 0 changed, 7 unchanged, 4 skipped", report.to_s
    assert_match "grants 0 created, 0 changed, 6 unchanged, 4 skipped", report.to_s
  end

  test "applying again is refused unless forced, and a forced run keeps what admins changed since" do
    import(apply: true)
    jjr = users(:jjr)
    finance = @dash.role("Finance readers")
    # After the cutover, admins manage access here: jjr moves off finance, the role loses the finance figures,
    # and the unused "Old group" role is removed.
    GrantChange.remove(Grant.find_by!(app: @dash, subject: jjr, app_role: finance))
    finance.update!(permissions: %w[module:customers:view])
    AuditEvent.record("app.role_changed", subject: @dash, data: { key: finance.key, permissions_removed: %w[management:finance:view] })
    old = @dash.role("Old group")
    old.destroy!
    AuditEvent.record("app.role_removed", subject: @dash, data: { key: old.key })

    error = assert_raises(DashboardImport::Refused) { import(apply: true) }
    assert_match "already applied", error.message
    assert_match "FORCE=1 APPLY=1", error.message

    dry = import(apply: false)
    assert_match "An import was already applied", dry.to_s
    assert_match "Run again with FORCE=1 APPLY=1", dry.to_s

    report = import(apply: true, force: true)
    assert report.applied?
    assert_empty Grant.where(app: @dash, subject: jjr, app_role: finance), "a removed grant is not granted again"
    assert_equal %w[module:customers:view], finance.reload.permissions, "an edited role is left as it is"
    assert_not AppRole.exists?(app: @dash, key: "Old group"), "a removed role is not created again"
    skips = report.lines.select { _1.action == "skip" }.to_h { [ _1.subject, _1.detail ] }
    assert_match "changed in the auth app since the import of", skips["Finance readers"]
    assert_match "removed in the auth app since the import of", skips["Old group"]
    assert_match "not granted again", skips["jjr@tourpaq.com → Finance readers"]
    event = AuditEvent.where(action: "import.dashboard").last
    assert_equal [ true, true ], [ event.data["applied"], event.data["forced"] ]
  end

  # The role editor's last-administrator guard (SPECS.md §23.2) applies to the import's role changes too.
  test "a role change that would leave nobody administering the app is refused and listed" do
    support = @dash.role("Support")
    support.update!(permissions: %w[admin:access:manage module:customers:view])
    grant_dashboard(users(:mwi), "Support")

    report = import(apply: true)

    assert_equal %w[admin:access:manage module:customers:view], support.reload.permissions
    detail = report.lines.detect { _1.action == "skip" && _1.subject == "Support" }&.detail
    assert_match "refused: Dashboard needs at least one active user with admin:access:manage", detail.to_s
    assert_not AuditEvent.where(action: "app.role_changed", app: @dash).any? { _1.data["key"] == "Support" }
  end

  test "a clean export checks clean, and nobody created by the import is announced as pending" do
    data = JSON.parse(@json)
    data["resolved_permissions"].reject! { %w[bob@tourpaq.com kim@tourpaq.com].include?(_1["email"]) }
    with_auth_config(teams_webhook_url: "https://teams.example.test/hook") do
      assert_no_enqueued_jobs(only: PendingUserNotificationJob) do
        report = import(apply: true, json: data.to_json)
        assert_empty report.differences
        assert_match "Check: every user's permissions match the export.", report.to_s
      end
    end
  end

  test "refuses a file whose format or version does not match, and other bad input" do
    error = assert_raises(DashboardImport::Refused) { import(apply: true, json: file_fixture("dashboard_export_version_2.json").read) }
    assert_match "version 2", error.message
    assert_raises(DashboardImport::Refused) { import(apply: true, json: JSON.parse(@json).merge("format" => "other").to_json) }
    assert_raises(DashboardImport::Refused) { import(apply: true, json: "not json") }
    assert_raises(DashboardImport::Refused) { import(apply: true, json: JSON.parse(@json).except("users").to_json) }
    App.where(id: @dash.id).update_all(slug: "dashboard-old")
    assert_match "run the seeds", assert_raises(DashboardImport::Refused) { import(apply: true) }.message
  end

  test "the rake task: dry run by default, APPLY=1 applies" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("auth:import_dashboard")
    path = file_fixture("dashboard_export.json").to_s
    task = Rake::Task["auth:import_dashboard"]
    task.reenable
    out, = capture_io { task.invoke(path) }
    assert_match "DRY RUN", out
    assert_nil User.find_by_email("new.bound@tourpaq.com")

    ENV["APPLY"] = "1"
    task.reenable
    out, = capture_io { task.invoke(path) }
    assert_match "APPLIED", out
    assert User.find_by_email("new.bound@tourpaq.com")

    # Applying again needs FORCE=1.
    task.reenable
    assert_raises(SystemExit) { capture_io { task.invoke(path) } }
    ENV["FORCE"] = "1"
    task.reenable
    out, = capture_io { task.invoke(path) }
    assert_match "APPLIED", out
  ensure
    ENV.delete("APPLY")
    ENV.delete("FORCE")
    Current.reset
  end
end
