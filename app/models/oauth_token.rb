# Extension credentials (SPECS.md §10): an opaque access token (tpx_<slug>_…, ACCESS_TTL) bound to
# the client's app, and a rotating refresh token. All tokens of one sign-in share a chain_id;
# reuse of a retired refresh token revokes the chain (oauth.refresh_reused). Stored as SHA-256.
# The OIDC provider (protocol milestone) issues, rotates and introspects them.
class OauthToken < ApplicationRecord
  include HashedToken

  KINDS = %w[access refresh].freeze
  ACCESS_TTL = 1.hour
  REFRESH_IDLE = 30.days
  ACCESS_PREFIX = "tpx_".freeze
  REFRESH_PREFIX = "tpr_".freeze

  belongs_to :client
  belongs_to :user
  belongs_to :replaced_by, class_name: "OauthToken", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :token_digest, :chain_id, :expires_at, presence: true

  scope :access, -> { where(kind: "access") }
  scope :refresh, -> { where(kind: "refresh") }
  scope :unrevoked, -> { where(revoked_at: nil) }
  scope :active, -> { unrevoked.where(expires_at: Time.current..) }

  def self.prefix_for(kind, app) = "#{kind.to_s == 'access' ? ACCESS_PREFIX : REFRESH_PREFIX}#{app.slug}_"

  def app = client.app
  def access? = kind == "access"
  def refresh? = kind == "refresh"
  def revoked? = revoked_at.present?
  def expired? = expires_at <= Time.current
  def retired? = replaced_by_id.present?
  def usable? = !revoked? && !expired? && !retired?

  def revoke!
    update!(revoked_at: Time.current) unless revoked?
  end

  # Revokes every token of this token's chain (all access and refresh tokens of one sign-in).
  def revoke_chain! = OauthToken.where(chain_id: chain_id, revoked_at: nil).update_all(revoked_at: Time.current, updated_at: Time.current)
end
