# A secret of a web client (SPECS.md §7.4): generated here, shown once, stored as SHA-256 with a
# hint (tpcs_ plus 6 characters). Optional expiry; the admin UI warns WARN_BEFORE ahead.
# Create through Client#generate_secret!; deleting one is a destroy (audited by the caller as
# client.secret_deleted).
class ClientSecret < ApplicationRecord
  include HashedToken
  hashed_token digest: :secret_digest, hint: :hint

  WARN_BEFORE = 30.days

  belongs_to :client
  belongs_to :created_by, class_name: "User", optional: true

  validates :secret_digest, :hint, presence: true

  scope :active, -> { where("client_secrets.expires_at IS NULL OR client_secrets.expires_at > ?", Time.current) }

  def expired? = expires_at.present? && expires_at <= Time.current
  def active? = !expired?
  def expiring_soon? = expires_at.present? && !expired? && expires_at <= WARN_BEFORE.from_now

  def touch_used!
    update_columns(last_used_at: Time.current) if last_used_at.nil? || last_used_at < 1.minute.ago
  end
end
