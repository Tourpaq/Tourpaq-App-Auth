# A person (SPECS.md §4): signed in with Entra at least once, or added in advance by an admin
# (pre-created: no entra_oid yet, bound by email at the first sign-in, §3.2).
#
# The domain methods below write their own audit events, so controllers and rake tasks do not:
#   disable! / enable! / make_admin! / remove_admin! / sign_out_everywhere!
# The last active admin cannot be disabled or lose admin (validation; the bang methods raise
# ActiveRecord::RecordInvalid, the message is in user.errors).
class User < ApplicationRecord
  has_many :sessions, dependent: :destroy
  has_many :group_memberships, dependent: :destroy
  has_many :groups, through: :group_memberships
  has_many :grants, as: :subject, dependent: :destroy
  has_many :personal_tokens, dependent: :destroy
  has_many :oauth_tokens, dependent: :destroy
  has_many :authorization_codes, dependent: :delete_all

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }
  normalizes :name, :upn, with: ->(value) { value.to_s.strip.presence }

  attr_readonly :sub
  before_validation { self.sub ||= SecureRandom.uuid }

  # A user created by their first Entra sign-in (bound at creation; pre-created users are not) is
  # pending: tell the admins in Teams when TEAMS_WEBHOOK_URL is set (§11.2). The Dashboard import (§23.5)
  # creates bound users too, and sets skip_pending_notification: those are not new colleagues.
  attr_accessor :skip_pending_notification
  after_create_commit -> { PendingUserNotificationJob.perform_later(self) },
                      if: -> { bound? && !admin? && !skip_pending_notification && PendingUserNotificationJob.enabled? }

  validates :sub, presence: true, uniqueness: true
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :entra_oid, uniqueness: { scope: :entra_tid }, allow_nil: true
  validate :keep_an_active_admin, on: :update

  scope :ordered, -> { order(Arel.sql("LOWER(COALESCE(users.name, users.email))"), :email) }
  scope :active, -> { where(disabled_at: nil) }
  scope :disabled, -> { where.not(disabled_at: nil) }
  scope :admins, -> { where(admin: true) }
  scope :unbound, -> { where(entra_oid: nil) }
  # Pending (§3.2, §11.2): active, not an admin, and given nothing yet: no direct grant with a
  # role and no group membership. They see "waiting for access"; admins see them first.
  scope :pending, -> {
    active.where(admin: false)
      .where.not(id: GroupMembership.select(:user_id))
      .where.not(id: Grant.where(subject_type: "User").where.not(app_role_id: nil).select(:subject_id))
  }

  def self.find_by_email(email) = find_by(email: email.to_s.strip.downcase)

  # True when `user` is an admin and no other active admin exists.
  def self.last_active_admin?(user) = user.admin? && user.active? && active.admins.where.not(id: user.id).none?

  def active? = disabled_at.nil?
  def disabled? = !active?
  def bound? = entra_oid.present?
  def pending? = User.pending.exists?(id)
  def display_name = name.presence || email

  # --- Access (§5.3) ---------------------------------------------------------------------------

  def effective_role(app) = EffectiveRole.for(self, app)
  def accessible_apps = EffectiveRole.apps_for(self)

  # --- Domain actions; each writes its audit event ----------------------------------------------

  # Disabling takes effect everywhere at once (§6): home and admin sessions end, extension tokens
  # are revoked, and personal tokens are refused while disabled (EffectiveRole says no access).
  # Refused (RecordInvalid) for the last active admin, and for the last active holder of an app's admin
  # permission (AppAdminGuard, §23.2).
  def disable!(actor: Current.user, reason: nil)
    return false if disabled?
    AppAdminGuard.protect(AppAdminGuard.apps_held_by(self)) do
      transaction do
        update!(disabled_at: Time.current)
        end_all_sessions!("disabled")
        revoke_oauth_tokens!
        AuditEvent.record("user.disabled", subject: self, actor: actor, data: { reason: reason }.compact)
      end
    end
    true
  rescue AppAdminGuard::LastAdmin => e
    self.disabled_at = nil
    clear_attribute_changes([ :disabled_at ])
    errors.add(:base, e.message)
    raise ActiveRecord::RecordInvalid, self
  end

  def enable!(actor: Current.user)
    return false if active?
    transaction do
      update!(disabled_at: nil)
      AuditEvent.record("user.enabled", subject: self, actor: actor)
    end
    true
  end

  def make_admin!(actor: Current.user)
    return false if admin?
    transaction do
      update!(admin: true)
      AuditEvent.record("user.admin_granted", subject: self, actor: actor)
    end
    true
  end

  # Ends the user's admin sessions too (their next admin request would refuse them anyway).
  def remove_admin!(actor: Current.user)
    return false unless admin?
    transaction do
      update!(admin: false)
      sessions.active.admin.find_each { _1.end!("not_admin") }
      AuditEvent.record("user.admin_revoked", subject: self, actor: actor)
    end
    true
  end

  # §6: home and admin sessions end, extension refresh (and access) tokens are revoked, and
  # sessions_valid_after is bumped so the apps end their sessions too. Personal tokens stay valid.
  def sign_out_everywhere!(actor: Current.user)
    transaction do
      update!(sessions_valid_after: Time.current)
      end_all_sessions!("signed_out_everywhere")
      revoke_oauth_tokens!
      AuditEvent.record("user.signed_out_everywhere", subject: self, actor: actor)
    end
    true
  end

  # sessions_valid_after as the apps get it (SPECS.md §6, §7.4, §8): Unix seconds, **rounded up**. Apps keep when
  # their session started in whole seconds and end it when it started before this value, so an app session that
  # started in the same second as the sign out (but before it) is ended too. A sign-in after the sign out needs a
  # new Entra sign-in (the auth sessions ended), which takes longer than the rest of that second.
  def sessions_valid_after_epoch = sessions_valid_after&.to_r&.ceil

  def end_all_sessions!(reason)
    sessions.active.update_all(ended_at: Time.current, end_reason: reason.to_s, updated_at: Time.current)
  end

  def revoke_oauth_tokens!(client: nil)
    scope = oauth_tokens.where(revoked_at: nil)
    scope = scope.where(client: client) if client
    scope.update_all(revoked_at: Time.current, updated_at: Time.current)
  end

  private

  def keep_an_active_admin
    losing = (will_save_change_to_disabled_at? && disabled_at.present?) || (will_save_change_to_admin? && !admin?)
    return unless losing && admin_in_database && disabled_at_in_database.nil?
    if User.active.admins.where.not(id: id).none?
      errors.add(:base, "#{display_name} is the last active admin: make someone else admin first")
    end
  end
end
