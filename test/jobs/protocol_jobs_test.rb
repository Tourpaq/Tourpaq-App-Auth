require "test_helper"

# The recurring jobs (config/recurring.yml; SPECS.md §12, §15, §19).
class ProtocolJobsTest < ActiveSupport::TestCase
  def issue_code(user, expires_at:)
    code = AuthorizationCode.new(client: clients(:irm_web), user: user, redirect_uri: OidcHelpers::IRM_REDIRECT, expires_at: expires_at)
    code.assign_new_token
    code.save!
    code
  end

  test "CleanupJob removes old codes, ends sessions past their limits, sweeps OAuth tokens without access, drops old counts" do
    old_code = issue_code(users(:alice), expires_at: 2.hours.ago)
    fresh_code = issue_code(users(:alice), expires_at: 1.minute.from_now)
    idle, = Session.start!(user: users(:alice), kind: "home")
    idle.update_columns(last_seen_at: 9.hours.ago)
    live, = Session.start!(user: users(:alice), kind: "home")
    admin, = Session.start!(user: users(:mwi), kind: "admin", entra_authenticated_at: 13.hours.ago)
    token = OauthToken.new(kind: "refresh", client: clients(:irm_extension), user: users(:bob), chain_id: "c1", expires_at: 1.day.from_now)
    token.assign_new_token(prefix: "tpr_irm_")
    token.save!
    UsageCount.increment!(clients(:irm_web), "access", day: 500.days.ago.to_date)
    UsageCount.increment!(clients(:irm_web), "access")

    CleanupJob.perform_now

    assert_not AuthorizationCode.exists?(old_code.id)
    assert AuthorizationCode.exists?(fresh_code.id)
    assert_equal "idle", idle.reload.end_reason
    assert_equal "expired", admin.reload.end_reason
    assert live.reload.active?
    assert_equal "system", AuditEvent.where(action: "session.expired").last.channel
    assert token.reload.revoked?, "bob has no access to the IRM"
    assert_equal [ Date.current ], UsageCount.pluck(:day)
  end

  test "TokenExpiryJob records token.expired once per expired token" do
    plain = PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "short", lifetime_days: 30)
    revoked = PersonalToken.find_by_plain(PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "gone", lifetime_days: 30))
    revoked.revoke!(actor: users(:alice))
    travel 31.days
    assert_difference -> { AuditEvent.where(action: "token.expired").count }, 1 do
      TokenExpiryJob.perform_now
      TokenExpiryJob.perform_now
    end
    event = AuditEvent.find_by(action: "token.expired")
    assert_equal [ PersonalToken.find_by_plain(plain), "irm", "system" ], [ event.subject, event.data["app"], event.channel ]
  end

  test "HeartbeatJob does nothing without IRM_HEARTBEAT_URL and never raises or logs the URL" do
    assert_nothing_raised { HeartbeatJob.perform_now }
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    with_auth_config(irm_heartbeat_url: "http://127.0.0.1:9/integrations/v1/heartbeat/secret-heartbeat-token/") do
      assert_nothing_raised { HeartbeatJob.perform_now }
    end
    Rails.logger = previous
    assert_match "[heartbeat] not sent", output.string
    assert_no_match "secret-heartbeat-token", output.string
  end

  test "HeartbeatJob calls the URL when the database answers" do
    requests = []
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      requests << client.gets
      client.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      client.close
    end
    with_auth_config(irm_heartbeat_url: "http://127.0.0.1:#{server.addr[1]}/integrations/v1/heartbeat/tok/") do
      HeartbeatJob.perform_now
    end
    thread.join(5)
    assert_match %r{\AGET /integrations/v1/heartbeat/tok/ HTTP}, requests.first
  ensure
    server&.close
  end

  test "the recurring schedule has the cleanup, token expiry and heartbeat jobs" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    %w[development production].each do |env|
      assert_equal %w[CleanupJob HeartbeatJob TokenExpiryJob], schedule[env].values.filter_map { _1["class"] }.sort, env
    end
  end
end
