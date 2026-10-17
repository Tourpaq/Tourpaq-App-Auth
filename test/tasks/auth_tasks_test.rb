require "test_helper"
require "rake"

# Break-glass console tasks (SPECS.md §15).
class AuthTasksTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("auth:admin")
  end

  def run_task(name, *args)
    task = Rake::Task[name]
    task.reenable
    out, = capture_io { task.invoke(*args) }
    out
  ensure
    Current.reset
  end

  test "auth:admin makes an existing user admin, audited from the console" do
    out = run_task("auth:admin", "Alice@Tourpaq.com")
    assert_match "alice@tourpaq.com is now an admin", out
    assert users(:alice).reload.admin?
    event = AuditEvent.last
    assert_equal [ "user.admin_granted", "console", nil ], [ event.action, event.channel, event.actor ]
  end

  test "auth:admin pre-creates an unknown user (fresh install)" do
    out = run_task("auth:admin", "first@tourpaq.com")
    assert_match "Pre-created", out
    user = User.find_by_email("first@tourpaq.com")
    assert user.admin?
    assert_not user.bound?
    assert_equal %w[user.precreated user.admin_granted], AuditEvent.order(:id).last(2).map(&:action)
  end

  test "auth:admin re-enables a disabled user" do
    run_task("auth:admin", "dave@tourpaq.com")
    assert users(:dave_disabled).reload.active?
    assert users(:dave_disabled).admin?
  end

  test "auth:disable disables and ends sessions" do
    session, = Session.start!(user: users(:alice))
    out = run_task("auth:disable", "alice@tourpaq.com")
    assert_match "disabled", out
    assert users(:alice).reload.disabled?
    assert_not session.reload.active?
    assert_equal [ "user.disabled", "console" ], [ AuditEvent.last.action, AuditEvent.last.channel ]
  end

  test "auth:disable refuses the last active admin and unknown emails" do
    users(:jjr).update!(admin: false)
    assert_raises(SystemExit) { run_task("auth:disable", "mwi@tourpaq.com") }
    assert users(:mwi).reload.active?
    assert_raises(SystemExit) { run_task("auth:disable", "nobody@tourpaq.com") }
  end

  # --- auth:client_secret (local testing, SPECS.md §24.4) ---

  test "auth:client_secret creates a secret, prints it once with the LOGIN_* lines, audited from the console" do
    out = run_task("auth:client_secret", "irm-web")
    plain = out[/^LOGIN_CLIENT_SECRET=(tpcs_[A-Za-z0-9_-]{43})$/, 1]
    assert plain, out
    assert_match "LOGIN_ISSUER=http://auth.example.com", out
    assert_match "LOGIN_CLIENT_ID=irm-web", out
    secret = clients(:irm_web).authenticate_secret(plain)
    assert secret, "the printed secret works"
    assert_not_equal plain, secret.secret_digest, "only its hash is stored"
    assert_in_delta 1.year.from_now.to_i, secret.expires_at.to_i, 60
    event = AuditEvent.last
    assert_equal [ "client.secret_created", "console", nil, clients(:irm_web) ], [ event.action, event.channel, event.actor, event.subject ]
    assert_not event.data.to_json.include?(plain)
  end

  test "auth:client_secret refuses unknown, non-web and disabled clients, and a third active secret" do
    assert_raises(SystemExit) { run_task("auth:client_secret", "nobody-web") }
    assert_raises(SystemExit) { run_task("auth:client_secret", "irm-extension") }
    assert_raises(SystemExit) { run_task("auth:client_secret", "admin") }
    clients(:kpi_web).update!(disabled_at: Time.current)
    assert_raises(SystemExit) { run_task("auth:client_secret", "kpi-web") }
    2.times { run_task("auth:client_secret", "irm-web") }
    assert_raises(SystemExit) { run_task("auth:client_secret", "irm-web") }
    assert_equal 2, clients(:irm_web).active_secrets.count
  end

  test "auth:client_secret is refused in production unless FORCE=1" do
    previous_env = Rails.env
    previous_force = ENV["FORCE"]
    Rails.env = "production"
    ENV.delete("FORCE")
    assert_raises(SystemExit) { run_task("auth:client_secret", "irm-web") }
    assert_equal 0, clients(:irm_web).active_secrets.count
    ENV["FORCE"] = "1"
    assert_match "LOGIN_CLIENT_SECRET=tpcs_", run_task("auth:client_secret", "irm-web")
  ensure
    Rails.env = previous_env
    previous_force.nil? ? ENV.delete("FORCE") : ENV["FORCE"] = previous_force
  end
end
