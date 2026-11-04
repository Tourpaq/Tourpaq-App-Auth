# A short-lived token for one app, issued to the MCP Gateway by the token exchange (SPECS.md §25.5, RFC 8693) in
# return for a person's gateway token (tpa_<gateway>_…). Format tpe_<app slug>_<43 chars>; stored as SHA-256 with a
# hint, never shown anywhere but the exchange's answer. The app introspects it like a personal token and learns the
# person, their MCP-channel role in the app and a scope no wider than the gateway token's.
#
#   token = ExchangedToken.find_by_plain(plain)
#   token.usable?    # unexpired, the gateway token still usable, the gateway client and app active, and the person
#                    # still holds an MCP role in the app
#
# It dies with its gateway token (revoking that deletes these) and expired rows go in the hourly CleanupJob.
class ExchangedToken < ApplicationRecord
  include HashedToken

  PREFIX = "tpe_".freeze
  TTL = 5.minutes
  KEEP_EXPIRED = 1.hour

  belongs_to :personal_token
  belongs_to :app
  belongs_to :client
  belongs_to :user

  validates :token_digest, :token_hint, :scope, :expires_at, presence: true

  scope :expired, -> { where(expires_at: ...Time.current) }

  def self.prefix_for(app) = "#{PREFIX}#{app.slug}_"

  def self.find_by_plain(plain)
    return nil unless plain.to_s.start_with?(PREFIX)
    includes(:user, :app, :client, personal_token: :app).find_by(token_digest: token_digest(plain))
  end

  def expired? = expires_at <= Time.current

  # The person's MCP-channel access to the audience now.
  def effective_role = EffectiveRole.for(user, app, channel: "mcp")

  def usable?
    !expired? && client.active? && app.active? && app.channel?("mcp") && personal_token.usable? && personal_token.gateway? &&
      effective_role.access?
  end
end
