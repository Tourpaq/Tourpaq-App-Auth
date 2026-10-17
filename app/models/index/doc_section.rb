# A heading in the index's documentation menu.
class Index::DocSection < ApplicationRecord
  has_many :docs, -> { order(:position, :title) }, class_name: "Index::Doc", dependent: :nullify

  before_validation { self.key = Index::Sluggable.slugify(key.presence || title) }
  validates :key, presence: true, uniqueness: true, format: { with: Index::Sluggable::SLUG_FORMAT }
  validates :title, presence: true

  scope :ordered, -> { order(:position, :title) }
end
