# A heading in the index's documentation menu. `visibility` is who sees its docs, as for a section (SPECS.md §24.3):
# "everyone" is all Tourpaq staff (Index::Viewer#staff?), "groups" only members of the chosen auth groups; with no
# group chosen nobody sees them.
#
#   Index::DocSection.visible_to(viewer)   # in the query: the viewer's groups', plus everyone's for staff
class Index::DocSection < ApplicationRecord
  has_many :docs, -> { order(:position, :title) }, class_name: "Index::Doc", dependent: :nullify
  has_many :doc_section_groups, class_name: "Index::DocSectionGroup", dependent: :delete_all
  # Changing who sees it counts as a change (updated_at), as for sections.
  has_many :groups, through: :doc_section_groups, class_name: "::Group", after_add: :groups_changed, after_remove: :groups_changed

  before_validation { self.key = Index::Sluggable.slugify(key.presence || title) }
  validates :key, presence: true, uniqueness: true, format: { with: Index::Sluggable::SLUG_FORMAT }
  validates :title, presence: true
  validates :visibility, inclusion: { in: Index::VISIBILITIES }

  scope :ordered, -> { order(:position, :title) }

  def self.visible_to(viewer)
    where(id: visible_ids(viewer))
  end

  # The ids of the doc sections the viewer may see, as a subquery.
  def self.visible_ids(viewer)
    base = unscoped
    ids = base.where(visibility: "groups", id: Index::DocSectionGroup.where(group_id: viewer.group_ids).select(:doc_section_id))
    ids = ids.or(base.where(visibility: "everyone")) if viewer.staff?
    ids.select(:id)
  end

  def restricted? = visibility == "groups"

  # "All Tourpaq staff" or "DK Tech, RO DevOps" (or "nobody yet").
  def visibility_label
    return Index::STAFF_LABEL unless restricted?
    names = groups.map(&:name).sort
    names.any? ? names.join(", ") : "Nobody yet (no group chosen)"
  end

  private

  def groups_changed(_group)
    touch if persisted? && !destroyed?
  end
end
