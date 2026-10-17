# A personal API/MCP token (SPECS.md §9): one app, a scope from that app's own scope list (default
# read / read_write; the Dashboard's public / all, §23.3), a lifetime of 30, 90 or 365 days. Format tpa_<app slug>_<43 chars>; stored as SHA-256 with a hint (prefix + 6 chars),
# shown once. At most MAX_ACTIVE active tokens per user.
#
#   plain = PersonalToken.issue!(user:, app:, name: "Claude Code", scope: "read", lifetime_days: 90)
#   token = PersonalToken.find_by_plain(plain)   # any state; check token.usable?
#   token.usable?          # not revoked/expired, user active, app active, user has access now
#   token.effective_role   # EffectiveRole result (the role caps the scope, §9.2)
#   token.revoke!(actor:)
#
# Tokens are not deleted when access is lost: they are refused while the user has no access (§6).
class PersonalToken < ApplicationRecord
  include HashedToken

  SCOPES = App::DEFAULT_TOKEN_SCOPES # the default list; each app has its own (App#token_scopes)
  LIFETIMES = [ 30, 90, 365 ].freeze
  DEFAULT_LIFETIME = 90
  MAX_ACTIVE = 20
  PREFIX = "tpa_".freeze
  REMIND_BEFORE = 7.days
  UNUSED_AFTER = 90.days

  belongs_to :user
  belongs_to :app
  belongs_to :revoked_by, class_name: "User", optional: true

  normalizes :name, with: ->(name) { name.to_s.strip }

  validates :name, presence: true, length: { maximum: 100 }
  validate :scope_of_the_app
  validates :token_digest, :token_hint, :expires_at, presence: true
  validate :within_limits, on: :create

  scope :active, -> { where(revoked_at: nil).where(expires_at: Time.current..) }
  scope :revoked, -> { where.not(revoked_at: nil) }
  scope :expiring_soon, -> { active.where(expires_at: ..REMIND_BEFORE.from_now) }
  scope :unused, -> { active.where("COALESCE(personal_tokens.last_used_at, personal_tokens.created_at) < ?", UNUSED_AFTER.ago) }
  scope :recent_first, -> { order(created_at: :desc) }

  def self.prefix_for(app) = "#{PREFIX}#{app.slug}_"

  # Creates the token and returns the plain value (shown once). Raises ActiveRecord::RecordInvalid
  # on a bad name/scope/lifetime, no access to the app, or MAX_ACTIVE reached.
  # scope: one of the app's token scopes; its lowest when nil.
  def self.issue!(user:, app:, name:, scope: nil, lifetime_days: DEFAULT_LIFETIME, actor: user)
    token = new(user: user, app: app, name: name, scope: scope.to_s.presence || app.lowest_token_scope)
    token.lifetime_days = lifetime_days
    plain = token.assign_new_token(prefix: prefix_for(app))
    transaction do
      token.save!
      AuditEvent.record("token.created", subject: token, actor: actor,
                        data: { user_id: user.id, app: app.slug, name: token.name, scope: token.scope, expires_at: token.expires_at.utc.iso8601, hint: token.token_hint })
    end
    plain
  end

  # Any token with this value (revoked and expired too); nil for anything not shaped like ours.
  def self.find_by_plain(plain)
    return nil unless plain.to_s.start_with?(PREFIX)
    includes(:user, :app).find_by(token_digest: token_digest(plain))
  end

  attr_reader :lifetime_days

  def lifetime_days=(days)
    @lifetime_days = days.to_i
    self.expires_at = @lifetime_days.days.from_now if LIFETIMES.include?(@lifetime_days)
  end

  def revoked? = revoked_at.present?
  def expired? = expires_at <= Time.current
  def active? = !revoked? && !expired?
  def read_write? = scope == "read_write"
  # The app's highest scope (read_write, the Dashboard's all): shown as "may change things / see everything".
  def highest_scope? = app.present? && scope == app.highest_token_scope && app.token_scopes.size > 1

  def effective_role = EffectiveRole.for(user, app)

  # Valid right now: active, the user and app are active, and the user has a role in the app.
  def usable? = active? && effective_role.access?

  def revoke!(actor: Current.user)
    return false if revoked?
    transaction do
      update!(revoked_at: Time.current, revoked_by: actor)
      AuditEvent.record("token.revoked", subject: self, actor: actor, data: { user_id: user_id, app: app.slug, name: name, hint: token_hint })
    end
    true
  end

  # Introspection records use at most once a minute (§9.2).
  def touch_used!
    update_columns(last_used_at: Time.current) if last_used_at.nil? || last_used_at < 1.minute.ago
  end

  private

  def scope_of_the_app
    return if app.nil?
    errors.add(:scope, "must be one of #{app.token_scopes.to_sentence(last_word_connector: ' or ', two_words_connector: ' or ')}") unless app.token_scopes.include?(scope)
  end

  def within_limits
    errors.add(:lifetime_days, "must be one of #{LIFETIMES.to_sentence(last_word_connector: ' or ')} days") if lifetime_days && !LIFETIMES.include?(lifetime_days)
    return unless user && app
    errors.add(:base, "#{user.display_name} is disabled") if user.disabled?
    errors.add(:app, "is not one you have access to") unless EffectiveRole.for(user, app).access?
    errors.add(:base, "You can hold at most #{MAX_ACTIVE} active tokens: revoke one first") if user.personal_tokens.active.count >= MAX_ACTIVE
  end
end
