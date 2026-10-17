# A menu group of the index (WWW "category"). `layout` is how it is shown: "cards" on the front page (WWW's
# audience everyone), or "table": a page of its own with a compact, filterable table and a tile on the front page
# (WWW's technical). `visibility` is who sees it: "everyone" signed in, or only members of the chosen auth groups
# (SPECS.md §24.3). A section restricted to groups with no group chosen is seen by nobody (the admin overview lists it).
#
#   Index::Section.visible_to(viewer)    # in the query: everyone's, plus those of the viewer's groups
class Index::Section < ApplicationRecord
  include Index::Sluggable

  LAYOUTS = %w[cards table].freeze

  has_many :entries, class_name: "Index::Entry", dependent: :nullify
  has_many :section_groups, class_name: "Index::SectionGroup", dependent: :delete_all
  # Changing who sees it counts as a change (updated_at): the import keeps what admins changed after it.
  has_many :groups, through: :section_groups, class_name: "::Group", after_add: :groups_changed, after_remove: :groups_changed

  slug_from :name
  validates :name, presence: true, uniqueness: true
  validates :slug, uniqueness: true
  validates :layout, inclusion: { in: LAYOUTS }
  validates :visibility, inclusion: { in: Index::VISIBILITIES }

  scope :ordered, -> { order(:position, :name) }
  scope :cards, -> { where(layout: "cards") }
  scope :tables, -> { where(layout: "table") }
  # Cards first, then tables, as in the menu (WWW: everyone first, then technical).
  scope :menu_order, -> { order(Arel.sql("CASE WHEN index_sections.layout = 'table' THEN 1 ELSE 0 END"), :position, :name) }

  def self.visible_to(viewer)
    where(id: visible_ids(viewer))
  end

  # The ids of the sections the viewer may see, as a subquery.
  def self.visible_ids(viewer)
    base = unscoped
    base.where(visibility: "everyone")
        .or(base.where(visibility: "groups", id: Index::SectionGroup.where(group_id: viewer.group_ids).select(:section_id)))
        .select(:id)
  end

  def table? = layout == "table"
  def cards? = !table?
  def restricted? = visibility == "groups"

  # What the API's `audience` field has always said (WWW): "everyone" for cards, "technical" for tables.
  def audience = table? ? "technical" : "everyone"

  # "Everyone signed in" or "DK Tech, RO DevOps" (or "nobody yet").
  def visibility_label
    return "Everyone signed in" unless restricted?
    names = groups.map(&:name).sort
    names.any? ? names.join(", ") : "Nobody yet (no group chosen)"
  end

  private

  def groups_changed(_group)
    touch if persisted? && !destroyed?
  end
end
