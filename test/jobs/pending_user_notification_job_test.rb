require "test_helper"

# The optional Teams post for new pending users (SPECS.md §11.2, §20.3).
class PendingUserNotificationJobTest < ActiveJob::TestCase
  WEBHOOK = "https://example.webhook.office.com/workflows/abc"

  setup do
    @posts = []
    @previous = PendingUserNotificationJob.transport
    PendingUserNotificationJob.transport = ->(url, payload) { @posts << [ url, payload ]; nil }
  end

  teardown { PendingUserNotificationJob.transport = @previous }

  test "a user created by their first sign-in is announced when TEAMS_WEBHOOK_URL is set" do
    with_auth_config(teams_webhook_url: WEBHOOK) do
      assert_enqueued_with(job: PendingUserNotificationJob) do
        EntraSignIn.call(FakeIdentity.auth_hash(email: "new.colleague@tourpaq.com", name: "New Colleague"))
      end
      perform_enqueued_jobs
    end
    assert_equal 1, @posts.size
    url, payload = @posts.first
    assert_equal WEBHOOK, url
    card = payload[:attachments].first[:content]
    assert_equal "New user waiting for access", card[:body].first[:text]
    assert_includes card[:body].last[:facts], { title: "Email", value: "new.colleague@tourpaq.com" }
    user = User.find_by_email("new.colleague@tourpaq.com")
    assert_equal "http://admin.example.com/users/#{user.id}", card[:actions].first[:url]
  end

  test "nothing is enqueued without a webhook, for pre-created users, or for admins" do
    assert_no_enqueued_jobs do
      EntraSignIn.call(FakeIdentity.auth_hash(email: "quiet@tourpaq.com"))
    end
    with_auth_config(teams_webhook_url: WEBHOOK) do
      assert_no_enqueued_jobs do
        User.create!(email: "precreated@tourpaq.com")
        User.create!(email: "boss@tourpaq.com", admin: true, entra_oid: "x", entra_tid: entra_tenant_id)
        EntraSignIn.call(FakeIdentity.auth_hash(email: "carol@contractor.example")) # binds carol, creates nobody
      end
    end
  end

  test "a user given access before the job runs is not announced" do
    with_auth_config(teams_webhook_url: WEBHOOK) do
      PendingUserNotificationJob.perform_now(users(:alice))
      PendingUserNotificationJob.perform_now(users(:bob))
    end
    assert_equal 1, @posts.size
  end

  test "without a webhook the job does nothing" do
    PendingUserNotificationJob.perform_now(users(:bob))
    assert_empty @posts
  end

  test "a failed post is retried" do
    PendingUserNotificationJob.transport = ->(_url, _payload) { "Teams answered HTTP 500" }
    with_auth_config(teams_webhook_url: WEBHOOK) do
      assert_enqueued_with(job: PendingUserNotificationJob) do
        PendingUserNotificationJob.perform_now(users(:bob))
      end
    end
  end
end
