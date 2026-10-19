# One entry of the index (WWW "app"): an application, a service or a host on the network, in a section, with links,
# the two pills (access level, login method) and an optional markdown details page.
#
# An entry may be tied to an auth App (SPECS.md §24.3): it is then shown only to users with access to that app, with
# their role(s), and its own visibility is not used. Every other entry has a visibility: "everyone" (all Tourpaq
# staff, Index::Viewer#staff?), or the chosen auth groups. An entry in a section is shown only when the section is
# visible too.
#
#   Index::Entry.visible_to(viewer)   # in the query, on every surface
#   Index::Entry.search("sql bravo")  # every term in the name, description, URL, address, owner, section or a link
class Index::Entry < ApplicationRecord
  include Index::Sluggable

  STATUSES = %w[live beta internal retired].freeze
  URL_FORMAT = Index::URL_FORMAT
  ICON_URL_FORMAT = Index::ICON_URL_FORMAT

  belongs_to :section, class_name: "Index::Section", optional: true
  belongs_to :app, class_name: "::App", optional: true
  belongs_to :access_level, class_name: "Index::AccessLevel", optional: true
  belongs_to :login_method, class_name: "Index::LoginMethod", optional: true
  has_many :links, -> { order(:position, :id) }, class_name: "Index::Link", dependent: :destroy, inverse_of: :entry
  has_many :entry_groups, class_name: "Index::EntryGroup", dependent: :delete_all
  # Changing who sees it counts as a change (updated_at): the import keeps what admins changed after it.
  has_many :groups, through: :entry_groups, class_name: "::Group", after_add: :groups_changed, after_remove: :groups_changed
  accepts_nested_attributes_for :links, allow_destroy: true,
    reject_if: ->(attrs) { attrs.slice("label", "url", "note").values.all?(&:blank?) }

  normalizes :url, :address, :owner, :repo, :icon, with: ->(value) { value.strip.presence }

  slug_from :name
  validates :name, :description, presence: true
  validates :slug, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :visibility, inclusion: { in: Index::VISIBILITIES }
  validates :url, :repo, format: { with: URL_FORMAT, message: "must start with https://, http:// or /" }, allow_nil: true
  validate :has_somewhere_to_go
  validate :icon_is_emoji_or_image
  validate :link_labels_are_unique

  # An app's entry follows the app's access; a visibility of its own would only confuse.
  before_validation { self.visibility = "everyone" if app_id.present? }
  after_save { entry_groups.delete_all if app_id.present? || visibility == "everyone" }

  scope :ordered, -> { order(:position, :name) }

  def self.visible_to(viewer)
    where(id: visible_ids(viewer))
  end

  # The ids of the entries the viewer may see, as a subquery: by its own rule (the app's access, the viewer's groups,
  # or everyone for staff), and in no section or a visible one.
  def self.visible_ids(viewer)
    base = unscoped
    own = base.where(app_id: nil, visibility: "groups", id: Index::EntryGroup.where(group_id: viewer.group_ids).select(:entry_id))
              .or(base.where(app_id: viewer.app_ids))
    own = own.or(base.where(app_id: nil, visibility: "everyone")) if viewer.staff?
    own.where(section_id: nil).or(own.where(section_id: Index::Section.visible_ids(viewer))).select(:id)
  end

  # One search term against the name, description, URL, address, owner, section and link labels and URLs (portable SQL).
  SEARCH_SQL = (%w[index_entries.name index_entries.description index_entries.url index_entries.address index_entries.owner
                   index_sections.name].map { |column| "LOWER(COALESCE(#{column}, '')) LIKE :p" } +
                [ "EXISTS (SELECT 1 FROM index_links WHERE index_links.entry_id = index_entries.id AND " \
                  "(LOWER(index_links.label) LIKE :p OR LOWER(index_links.url) LIKE :p))" ]).join(" OR ").freeze

  # Matches every term (WWW's search).
  def self.search(query)
    terms = query.to_s.downcase.split
    return none if terms.empty?

    terms.inject(left_joins(:section)) { |scope, term| scope.where(SEARCH_SQL, p: "%#{sanitize_sql_like(term)}%") }
  end

  # Where the card's title points: the entry itself, else its first link.
  def primary_url
    url || links.first&.url
  end

  def page? = body.present?
  def icon_url? = icon.present? && ICON_URL_FORMAT.match?(icon)
  def restricted? = app_id.nil? && visibility == "groups"

  def initials
    name.split(/[\s\-_]+/).reject(&:blank?).first(2).map { |w| w[0] }.join.upcase.presence || "?"
  end

  # "Users with access to IRM", "All Tourpaq staff", "DK Tech, RO DevOps".
  def visibility_label
    return "Users with access to #{app.name}" if app
    return Index::STAFF_LABEL unless restricted?
    names = groups.map(&:name).sort
    names.any? ? names.join(", ") : "Nobody yet (no group chosen)"
  end

  private

  def groups_changed(_group)
    touch if persisted? && !destroyed?
  end

  def has_somewhere_to_go
    return if url.present? || address.present? || links.reject(&:marked_for_destruction?).any?

    errors.add(:base, "Give it a URL, an address, or at least one link, so the card points somewhere")
  end

  def icon_is_emoji_or_image
    return if icon.blank?

    if icon.match?(%r{\A(?:https?:)?/})
      errors.add(:icon, "is not a usable image URL") unless ICON_URL_FORMAT.match?(icon)
    elsif icon.include?("://") || icon.start_with?("www.")
      errors.add(:icon, "looks like a link but doesn't start with https://")
    elsif icon.length > 8
      errors.add(:icon, "should be a single emoji or an image URL")
    end
  end

  # Checked here rather than on Index::Link, because new links aren't in the database yet.
  def link_labels_are_unique
    labels = links.reject(&:marked_for_destruction?).map { |l| l.label.to_s.strip.downcase }.reject(&:blank?)
    duplicates = labels.tally.select { |_, n| n > 1 }.keys
    errors.add(:base, "Two links share the label #{duplicates.first.inspect}") if duplicates.any?
  end
end
