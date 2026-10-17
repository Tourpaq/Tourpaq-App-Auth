# A URL-friendly slug derived from a name when left blank (from WWW). `to_param` uses the saved slug, so a form
# re-rendered after a failed rename still posts to a URL that exists.
module Index::Sluggable
  extend ActiveSupport::Concern

  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  class_methods do
    def slug_from(attribute)
      before_validation { self.slug = Index::Sluggable.slugify(public_send(attribute)) if slug.blank? }
      validates :slug, presence: true, format: { with: SLUG_FORMAT, message: "may only contain a-z, 0-9 and dashes" }
    end
  end

  def self.slugify(value)
    value.to_s.parameterize.presence
  end

  def to_param
    slug_in_database.presence || slug
  end
end
