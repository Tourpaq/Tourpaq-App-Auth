# A documentation page of the index, written in markdown on the admin host. Docs are for everyone signed in.
class Index::Doc < ApplicationRecord
  belongs_to :doc_section, class_name: "Index::DocSection", optional: true

  before_validation { self.slug = Index::Sluggable.slugify(title) if slug.blank? }
  validates :title, presence: true
  validates :slug, presence: true, format: { with: Index::Sluggable::SLUG_FORMAT, message: "may only contain a-z, 0-9 and dashes" },
                   uniqueness: { scope: :doc_section_id, message: "is already used in this section" }

  scope :ordered, -> { order(:position, :title) }

  # The path on the index host (WWW's paths, so old links keep working behind the www.app redirect).
  def path
    doc_section ? "/docs/#{doc_section.key}/#{slug}" : "/docs/#{slug}"
  end
end
