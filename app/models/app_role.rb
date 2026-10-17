# One role of an app (SPECS.md §5.1). Position orders them, lowest first (unique per app).
# A role still used by a grant cannot be removed: reassign the grants first.
#
# In a multiple-roles app (§23.2) a role is a named permission set: its key is a name as people write it
# ("Finance readers", the Dashboard's group names), and `permissions` holds permission keys
# ("module:customers:view") or "*" (everything). Keys the app's catalogue does not know are kept and flagged
# (`unknown_permissions`), never dropped. Single-role apps keep lowercase keys and no permissions.
class AppRole < ApplicationRecord
  WILDCARD = "*".freeze
  # "<scope>:<id>:<action>" and the like: letters, digits, _ . - separated by colons (SPECS.md §23.1).
  PERMISSION_FORMAT = /\A[A-Za-z0-9_.\-]+(:[A-Za-z0-9_.\-*]+)*\z/
  SINGLE_KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/
  # A role name in a multiple-roles app: printable, no leading/trailing space, no control characters.
  NAME_FORMAT = /\A[^\s[:cntrl:]]([^[:cntrl:]]*[^\s[:cntrl:]])?\z/
  MAX_PERMISSIONS = 500

  belongs_to :app, inverse_of: :roles
  has_many :grants, dependent: :restrict_with_error

  normalizes :key, with: ->(key) { key.to_s.strip.squeeze(" ") }

  before_validation { self.key = key.to_s.downcase if key && !multiple? }
  before_validation { self.position ||= (app&.roles&.map(&:position)&.compact&.max || 0) + 1 }

  validates :key, presence: true, length: { maximum: 80 }
  validates :key, format: { with: SINGLE_KEY_FORMAT, message: "must be lowercase letters, digits and underscores" }, unless: :multiple?
  validates :key, format: { with: NAME_FORMAT, message: "must be printable text" }, if: :multiple?
  validates :key, uniqueness: { scope: :app_id, case_sensitive: false }
  validates :position, presence: true, uniqueness: { scope: :app_id }
  validate :permissions_are_keys

  def to_s = key
  def in_use? = grants.exists?
  def multiple? = app&.multiple_roles? || false

  # Permission keys, sorted and without duplicates ("*" first when present).
  def permissions = Array(self[:permissions])

  def permissions=(keys)
    super(self.class.normalize_permissions(keys))
  end

  def wildcard? = permissions.include?(WILDCARD)

  # Does this role give `key` (directly or through "*")?
  def grants_permission?(key) = wildcard? || permissions.include?(key.to_s)

  # Keys the app's catalogue does not know ([] until the app has pushed one; "*" is never unknown).
  def unknown_permissions
    return [] unless app&.catalogue_pushed?
    known = app.catalogue_keys.to_set
    permissions.reject { _1 == WILDCARD || known.include?(_1) }
  end

  # From a form or an export: strings, stripped, without blanks or duplicates, sorted ("*" sorts first).
  def self.normalize_permissions(keys)
    Array(keys).map { _1.to_s.strip }.reject(&:blank?).uniq.sort
  end

  private

  def permissions_are_keys
    list = permissions
    errors.add(:permissions, "are too many (at most #{MAX_PERMISSIONS})") if list.size > MAX_PERMISSIONS
    bad = list.reject { _1 == WILDCARD || (_1.length <= 100 && _1.match?(PERMISSION_FORMAT)) }
    errors.add(:permissions, "are not permission keys: #{bad.first(5).join(', ')}") if bad.any?
    errors.add(:permissions, "are only for apps with multiple roles") if list.any? && app && !multiple?
  end
end
