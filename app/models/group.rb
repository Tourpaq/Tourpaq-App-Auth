# A named set of users (SPECS.md §5.2), such as DK Tech, RO DevOps or RO Dev. Managed here only:
# Entra groups are not read.
class Group < ApplicationRecord
  has_many :group_memberships, dependent: :destroy
  has_many :users, through: :group_memberships
  has_many :grants, as: :subject, dependent: :destroy

  normalizes :name, with: ->(name) { name.to_s.strip }

  validates :name, presence: true, uniqueness: { case_sensitive: false }

  scope :ordered, -> { order(:name) }
end
