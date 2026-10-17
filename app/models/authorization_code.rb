# An OIDC authorization code (SPECS.md §7.2): single use, CODE_TTL. Only its SHA-256 is stored.
# The OIDC provider (protocol milestone) issues and redeems them.
class AuthorizationCode < ApplicationRecord
  include HashedToken
  hashed_token digest: :code_digest, hint: nil

  CODE_TTL = 60.seconds

  belongs_to :client
  belongs_to :user
  belongs_to :session, optional: true

  validates :code_digest, :redirect_uri, :expires_at, presence: true

  scope :expired, -> { where(expires_at: ...Time.current) }

  def expired? = expires_at <= Time.current
  def used? = used_at.present?
  def usable? = !used? && !expired?
end
