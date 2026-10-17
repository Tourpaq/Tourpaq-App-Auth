# One entry of an app's permission catalogue (SPECS.md §23.2): key, label and group label, in the app's own
# order. The app pushes the whole catalogue with PUT /api/v1/catalogue (CataloguePush), which replaces it; the
# role editor shows it as checkboxes grouped by group label, and role keys missing from it are flagged.
class AppPermission < ApplicationRecord
  belongs_to :app, inverse_of: :catalogue

  validates :key, presence: true, length: { maximum: 100 }, format: { with: AppRole::PERMISSION_FORMAT },
                  uniqueness: { scope: :app_id }
  validates :label, :group_label, length: { maximum: 200 }

  def display_label = label.presence || key
  def display_group = group_label.presence || "Other"
end
