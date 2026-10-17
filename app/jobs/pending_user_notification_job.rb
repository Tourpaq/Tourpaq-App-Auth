require "net/http"

# Tells the admins in Teams that someone signed in for the first time and is waiting for access
# (SPECS.md §11.2, §20.3). Optional: only when TEAMS_WEBHOOK_URL is set (a Teams workflow webhook,
# as in the IRM's Notifications::Teams). The card links to the user's page on the admin host.
#
# Enqueued by User (after_create_commit) for users created at their first Entra sign-in; pre-created
# users are not pending. Skipped when the user is no longer pending by the time it runs. A failed
# post is retried a few times, then dropped (the admin sidebar count still shows the user).
class PendingUserNotificationJob < ApplicationJob
  class DeliveryFailed < StandardError; end

  queue_as :default
  retry_on DeliveryFailed, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  # How the card is posted: ->(url, payload) { nil on success, else the error text }. Tests replace it.
  class_attribute :transport, default: ->(url, payload) { deliver(url, payload) }

  def self.enabled? = Rails.configuration.x.auth.teams_webhook_url.present?

  def perform(user)
    url = Rails.configuration.x.auth.teams_webhook_url
    return if url.blank? || !user.pending?
    error = transport.call(url, self.class.card(user))
    raise DeliveryFailed, error if error
  end

  def self.card(user)
    link = "#{AuthHosts.admin_url}/users/#{user.id}"
    { type: "message", attachments: [ { contentType: "application/vnd.microsoft.card.adaptive", content: {
      "$schema" => "http://adaptivecards.io/schemas/adaptive-card.json", type: "AdaptiveCard", version: "1.4",
      body: [
        { type: "TextBlock", size: "Medium", weight: "Bolder", wrap: true, text: "New user waiting for access" },
        { type: "FactSet", facts: [
          { title: "Name", value: user.name.presence || "—" },
          { title: "Email", value: user.email },
          { title: "First sign-in", value: user.created_at.utc.strftime("%Y-%m-%d %H:%M UTC") }
        ] }
      ],
      actions: [ { type: "Action.OpenUrl", title: "Open in Tourpaq Admin", url: link } ]
    } } ] }
  end

  # nil on success, otherwise the error text (never the webhook URL: it is a credential).
  def self.deliver(url, payload)
    uri = URI(url)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) do |http|
      http.post(uri.request_uri, JSON.generate(payload), "Content-Type" => "application/json")
    end
    res.code.to_i.between?(200, 299) ? nil : "Teams answered HTTP #{res.code}"
  rescue StandardError => e
    "#{e.class}: #{e.message}".truncate(200)
  end
end
