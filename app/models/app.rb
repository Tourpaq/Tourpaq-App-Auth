# One of our applications (SPECS.md §5.1), such as the IRM. It has an ordered list of roles
# (lowest first; at least one), one or more clients, and grants.
#
#   app.roles            # AppRole, lowest first
#   app.role_keys        # ["viewer", "responder", "editor", "admin"]
#   app.role("editor")   # the AppRole or nil
#   app.rank(role)       # 0-based position of an AppRole or key; higher = more
#   app.reorder_roles!(%w[viewer editor responder admin])
#
# Permission-carrying roles (SPECS.md §23.2), opt-in per app:
#
#   app.multiple_roles?      # a user may hold several roles; they get the union of the roles' permissions
#   app.permissions_claim    # "dashboard_permissions": the ID-token claim with that union (multiple-roles apps)
#   app.admin_permission     # "admin:access:manage": the last-administrator guard keeps one active holder
#   app.catalogue            # AppPermission rows pushed by the app (PUT /api/v1/catalogue)
#   app.catalogue_keys       # their keys
#   app.unknown_permissions  # { AppRole => ["old:key"] } for role keys missing from the catalogue
#
# Token scopes (§23.3): app.token_scopes is the ordered list, lowest first (default read < read_write);
# app.highest_token_scope is what an extension token gets.
class App < ApplicationRecord
  DEFAULT_TOKEN_SCOPES = %w[read read_write].freeze
  SCOPE_FORMAT = /\A[a-z][a-z0-9_]*\z/

  has_many :roles, -> { order(:position) }, class_name: "AppRole", inverse_of: :app, dependent: :destroy
  has_many :catalogue, -> { order(:position, :key) }, class_name: "AppPermission", inverse_of: :app, dependent: :delete_all
  has_many :clients, dependent: :restrict_with_error
  has_many :grants, dependent: :destroy
  has_many :personal_tokens, dependent: :restrict_with_error

  SLUG_FORMAT = /\A[a-z0-9]+(-[a-z0-9]+)*\z/
  # Claims the ID token, userinfo or JWT already define: a role claim with one of these names would replace
  # them (sub = "admin" for everybody), so it is refused.
  RESERVED_CLAIMS = %w[
    iss sub aud exp nbf iat jti auth_time nonce acr amr azp at_hash c_hash sid typ scope client_id
    email email_verified name given_name family_name middle_name nickname preferred_username profile picture
    website gender birthdate zoneinfo locale phone_number phone_number_verified address updated_at
    sessions_valid_after
  ].freeze

  normalizes :slug, with: ->(slug) { slug.to_s.strip.downcase }
  normalizes :admin_permission, with: ->(key) { key.to_s.strip.presence }
  attr_readonly :slug # used in claims and token prefixes

  before_validation { self.role_claim = self.class.default_role_claim(slug, multiple: multiple_roles?) if role_claim.blank? && slug.present? }
  before_validation { self.token_scopes = DEFAULT_TOKEN_SCOPES.dup if Array(token_scopes).empty? }

  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT, message: "must be lowercase letters, digits and dashes" }
  validates :name, presence: true
  validates :role_claim, presence: true, format: { with: /\A[a-z][a-z0-9_]*\z/ },
                         exclusion: { in: RESERVED_CLAIMS, message: "is a standard claim name; use e.g. <slug>_role" }
  validates :url, format: { with: %r{\Ahttps?://\S+\z}, message: "must be an http(s) URL" }, allow_blank: true
  validates :admin_permission, format: { with: AppRole::PERMISSION_FORMAT, message: "must be a permission key such as admin:access:manage" },
                               length: { maximum: 100 }, allow_nil: true
  validate :at_least_one_role
  validate :permissions_claim_is_free
  validate :token_scopes_are_valid
  validate :single_role_switch_is_safe, on: :update

  scope :ordered, -> { order(:name) }
  scope :active, -> { where(disabled_at: nil) }
  scope :in_launcher, -> { active.where(show_in_launcher: true) }

  # "<slug>_role" with dashes as underscores: irm_role, kpi_role, azure_cost_role. A multiple-roles app's
  # claim holds a list: "<slug>_roles" (dashboard_roles).
  def self.default_role_claim(slug, multiple: false) = "#{slug.to_s.tr('-', '_')}_#{multiple ? 'roles' : 'role'}"

  def active? = disabled_at.nil?
  def disabled? = !active?

  def role_keys = roles.map(&:key)
  def role(key) = multiple_roles? ? roles.detect { _1.key.casecmp?(key.to_s) } : roles.detect { _1.key == key.to_s }
  def lowest_role = roles.first
  def highest_role = roles.last

  # 0-based rank of an AppRole or role key in this app's order; nil when unknown.
  def rank(role_or_key)
    key = role_or_key.respond_to?(:key) ? role_or_key.key : role_or_key.to_s
    role_keys.index(key)
  end

  # Appends a role at the top of the order.
  def add_role!(key, description: nil, permissions: [])
    roles.create!(key: key, description: description, permissions: permissions, position: (roles.maximum(:position) || 0) + 1)
  end

  # Sets the order (lowest first) from a full list of the app's role keys. Positions are unique per
  # app, so they move through negative values inside one transaction.
  def reorder_roles!(keys)
    keys = keys.map(&:to_s)
    raise ArgumentError, "give every role of #{slug} exactly once" unless keys.sort == role_keys.sort
    transaction do
      roles.each { _1.update_columns(position: -_1.position) }
      keys.each_with_index { |key, index| roles.find_by!(key: key).update_columns(position: index + 1, updated_at: Time.current) }
    end
    roles.reset
    self
  end

  # --- Permission-carrying roles (§23.2) ---------------------------------------------------------

  # "<slug>_permissions" (dashes as underscores): the sorted union of the user's roles' permissions.
  def permissions_claim = multiple_roles? ? "#{slug.to_s.tr('-', '_')}_permissions" : nil

  def catalogue_keys = catalogue.map(&:key)
  def catalogue_pushed? = catalogue_pushed_at.present?

  # Roles holding keys the pushed catalogue does not know, with those keys. Empty until the app has pushed
  # a catalogue (nothing to compare against yet). "*" is never unknown.
  def unknown_permissions
    return {} unless catalogue_pushed?
    known = catalogue_keys.to_set
    roles.each_with_object({}) do |role, found|
      unknown = role.permissions.reject { _1 == AppRole::WILDCARD || known.include?(_1) }
      found[role] = unknown if unknown.any?
    end
  end

  # --- Token scopes (§23.3) ------------------------------------------------------------------------

  def token_scopes = Array(self[:token_scopes]).presence || DEFAULT_TOKEN_SCOPES
  def lowest_token_scope = token_scopes.first
  def highest_token_scope = token_scopes.last

  # From a form: "public all" / "public, all" / one per line, lowest first.
  def token_scope_list = token_scopes.join(" ")
  def token_scope_list=(value)
    self.token_scopes = value.to_s.split(/[\s,]+/).map { _1.strip.downcase }.reject(&:blank?).uniq
  end

  private

  def at_least_one_role
    # A multiple-roles app may start without roles: they are permission sets added later (the Dashboard's come
    # from its import, §23.5).
    return if multiple_roles?
    errors.add(:roles, "need at least one role") if roles.reject(&:marked_for_destruction?).empty?
  end

  def permissions_claim_is_free
    claim = permissions_claim or return
    errors.add(:role_claim, "must differ from the permissions claim #{claim}") if role_claim == claim
    errors.add(:slug, "gives the permissions claim #{claim}, a standard claim name") if RESERVED_CLAIMS.include?(claim)
  end

  def token_scopes_are_valid
    scopes = Array(self[:token_scopes])
    if scopes.empty? || scopes.any? { !_1.to_s.match?(SCOPE_FORMAT) } || scopes.uniq.size != scopes.size
      errors.add(:token_scopes, "must be one or more distinct lowercase names (letters, digits, underscores), lowest first")
    end
    return if new_record? || !will_save_change_to_token_scopes?
    in_use = personal_tokens.active.where.not(scope: scopes).distinct.pluck(:scope)
    errors.add(:token_scopes, "still in use by active tokens: #{in_use.sort.join(', ')}") if in_use.any?
  end

  # Turning multiple roles off is refused while somebody holds several roles, or a role name is not a plain key.
  def single_role_switch_is_safe
    return unless will_save_change_to_multiple_roles? && !multiple_roles?
    if grants.group(:subject_type, :subject_id).having("COUNT(*) > 1").count.any?
      errors.add(:multiple_roles, "cannot be turned off while a user or group holds several roles")
    end
    if roles.any? { !_1.key.match?(AppRole::SINGLE_KEY_FORMAT) }
      errors.add(:multiple_roles, "cannot be turned off while role names are not lowercase keys")
    end
  end
end
