# Per-request context, as in the IRM. Controllers set it (Authentication / IndexAuthentication /
# AdminAuthentication), rake tasks set channel "console", jobs "system". AuditEvent.record reads it.
class Current < ActiveSupport::CurrentAttributes
  # session: the Session row (kind "home" on the auth host, "index" on the index host, "admin" on the admin host) that
  # authenticated this request. client: the OAuth client that authenticated an API call.
  attribute :session, :client, :ip_address, :user_agent, :channel

  def user = session&.user

  def channel = super || "web"
end
