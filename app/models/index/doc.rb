# A documentation page of the index, written in markdown on the admin host. Who sees it is its doc section's
# visibility; a doc in no section is for all Tourpaq staff (SPECS.md §24.3).
#
#   Index::Doc.visible_to(viewer)   # in the query, on every surface
class Index::Doc < ApplicationRecord
  belongs_to :doc_section, class_name: "Index::DocSection", optional: true

  before_validation { self.slug = Index::Sluggable.slugify(title) if slug.blank? }
  validates :title, presence: true
  validates :slug, presence: true, format: { with: Index::Sluggable::SLUG_FORMAT, message: "may only contain a-z, 0-9 and dashes" },
                   uniqueness: { scope: :doc_section_id, message: "is already used in this section" }

  scope :ordered, -> { order(:position, :title) }

  def self.visible_to(viewer)
    sectioned = where(doc_section_id: Index::DocSection.visible_ids(viewer))
    viewer.staff? ? sectioned.or(where(doc_section_id: nil)) : sectioned
  end

  # The path on the index host (WWW's paths, so old links keep working behind the www.app redirect).
  def path
    doc_section ? "/docs/#{doc_section.key}/#{slug}" : "/docs/#{slug}"
  end
end
