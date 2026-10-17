# (app, user or group) → role (SPECS.md §5.3). A grant to a user with no role (app_role nil)
# means "no access" and overrides that user's groups for the app.
#
# One grant per (app, subject) in a single-role app. In a multiple-roles app (§23.2) a subject may hold
# several grants, one per role, and a user's "no access" grant excludes every other grant of that user in
# the app. (The database index is unique per (app, subject, role); these rules live here.)
#
# Grants do not audit themselves: the admin UI records grant.created / grant.changed /
# grant.removed with the before/after effective roles of each affected user (GrantChange).
class Grant < ApplicationRecord
  SUBJECT_TYPES = %w[User Group].freeze

  belongs_to :app
  belongs_to :subject, polymorphic: true
  belongs_to :app_role, optional: true

  validates :subject_type, inclusion: { in: SUBJECT_TYPES }
  validate :one_grant_per_subject_or_role
  validate :role_belongs_to_app
  validate :no_access_only_for_users

  scope :for_users, -> { where(subject_type: "User") }
  scope :for_groups, -> { where(subject_type: "Group") }

  # Grants this one replaces in the same change (GrantChange.add): left out of the rules above.
  attr_accessor :replacing_ids

  def no_access? = app_role_id.nil?
  def role = app_role

  # Every user whose effective role this grant can affect.
  def affected_users = subject.is_a?(Group) ? subject.users : User.where(id: subject_id)

  private

  def siblings
    scope = Grant.where(app_id: app_id, subject_type: subject_type, subject_id: subject_id)
    scope = scope.where.not(id: id) if persisted?
    scope = scope.where.not(id: replacing_ids) if replacing_ids.present?
    scope
  end

  def one_grant_per_subject_or_role
    return unless app && subject_id
    if !app.multiple_roles?
      errors.add(:subject_id, "already has a grant for #{app.name}") if siblings.exists?
    elsif no_access?
      errors.add(:base, "No access excludes the other grants of #{app.name}: remove them first") if siblings.exists?
    elsif siblings.where(app_role_id: nil).exists?
      errors.add(:base, "#{subject.try(:display_name) || 'This user'} has no access to #{app.name}: remove that first")
    elsif siblings.where(app_role_id: app_role_id).exists?
      errors.add(:app_role, "is already granted")
    end
  end

  def role_belongs_to_app
    errors.add(:app_role, "is not a role of #{app.name}") if app_role && app && app_role.app_id != app_id
  end

  def no_access_only_for_users
    errors.add(:app_role, "is required for a group grant") if no_access? && subject_type == "Group"
  end
end
