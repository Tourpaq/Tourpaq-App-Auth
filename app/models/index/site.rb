# Site-wide text of the index. There is exactly one row; `Index::Site.current` creates it on demand.
class Index::Site < ApplicationRecord
  validates :title, presence: true

  def self.current
    first || create!(title: "Tourpaq Index")
  end

  def brand_or_title
    brand.presence || title
  end
end
