# Shared by the two vocabularies shown as pills on every entry: Index::AccessLevel and Index::LoginMethod (from WWW).
# `tone` colours the pill's dot.
module Index::Toned
  extend ActiveSupport::Concern

  # ok is the reassuring case, warn the one worth noticing, danger the one worth fixing.
  TONES = %w[ok warn danger neutral].freeze
  KEY_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  included do
    has_many :entries, class_name: "Index::Entry", dependent: :nullify

    before_validation { self.key = Index::Toned.normalise(key.presence || label) }
    validates :key, presence: true, uniqueness: true,
                    format: { with: KEY_FORMAT, message: "may only contain a-z, 0-9 and dashes" }
    validates :label, presence: true
    validates :tone, inclusion: { in: TONES }

    scope :ordered, -> { order(:position, :label) }
  end

  # Loose matching, as the markdown site did: "Azure VPN", "azure vpn" and "azure-vpn" are all the same key.
  def self.normalise(value)
    value.to_s.strip.downcase.gsub(/[\s_]+/, "-").presence
  end
end
