require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  test "record fills actor, IP, user agent and channel from Current, and the app from the subject" do
    session, = Session.start!(user: users(:mwi))
    Current.session = session
    Current.ip_address = "10.0.0.9"
    Current.user_agent = "Firefox"
    Current.channel = "admin"
    event = AuditEvent.record("client.created", subject: clients(:irm_web), data: { client_id: "irm-web" })
    assert_equal [ users(:mwi), "10.0.0.9", "Firefox", "admin", apps(:irm) ], [ event.actor, event.ip_address, event.user_agent, event.channel, event.app ]
    assert_equal({ "client_id" => "irm-web" }, event.data)
  ensure
    Current.reset
  end

  test "an App subject is its own app; channel defaults to web" do
    event = AuditEvent.record("app.updated", subject: apps(:kpi), actor: nil)
    assert_equal apps(:kpi), event.app
    assert_equal "web", event.channel
  end

  test "actions are dotted names, and events are read-only" do
    assert_raises(ActiveRecord::RecordInvalid) { AuditEvent.record("nodots") }
    event = AuditEvent.record("user.created", subject: users(:bob))
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(action: "user.changed") }
  end
end
