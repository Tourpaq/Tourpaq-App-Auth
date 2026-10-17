# Append-only record of who did what (SPECS.md §12). Actions are dotted names such as
# "auth.login", "user.created", "grant.changed". Kept indefinitely.
#
#   AuditEvent.record("user.disabled", subject: user, data: { reason: "left" })
#
# Fills in the actor, IP, user agent and channel from Current unless given, and the app from the
# subject (an App, or anything with #app) so the log can be filtered by app.
class AuditEvent < ApplicationRecord
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :subject, polymorphic: true, optional: true
  belongs_to :app, optional: true

  validates :action, presence: true, format: { with: /\A[a-z_]+(\.[a-z_]+)+\z/ }

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def readonly? = persisted?

  def self.record(action, subject: nil, actor: Current.user, app: nil, data: {})
    app ||= subject if subject.is_a?(App)
    app ||= subject.app if subject.respond_to?(:app) && subject.app.is_a?(App)
    create!(action: action, subject: subject, actor: actor, app: app, data: data,
            channel: Current.channel, ip_address: Current.ip_address, user_agent: Current.user_agent&.truncate(255))
  end
end
