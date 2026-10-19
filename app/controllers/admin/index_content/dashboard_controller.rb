# The index content overview on the admin host (WWW's admin overview): counts, the gaps worth fixing first (entries
# without a section, access level or login method; sections, doc sections and entries restricted to groups with no
# group chosen, which nobody sees; no group marked staff, so the content for all staff is seen by admins only; auth
# apps in the launcher that no entry stands for) and what changed lately.
class Admin::IndexContent::DashboardController < Admin::IndexContent::BaseController
  def show
    @counts = {
      "Entries" => [ Index::Entry.count, admin_index_entries_path ],
      "Sections" => [ Index::Section.count, admin_index_sections_path ],
      "Docs" => [ Index::Doc.count, admin_index_docs_path ],
      "Access levels" => [ Index::AccessLevel.count, admin_index_access_levels_path ],
      "Login methods" => [ Index::LoginMethod.count, admin_index_login_methods_path ]
    }
    # A blank on an access overview is the thing worth fixing first.
    @gaps = Index::Entry.where(access_level_id: nil).or(Index::Entry.where(login_method_id: nil)).or(Index::Entry.where(section_id: nil))
                        .includes(:section, :access_level, :login_method).ordered
    @unseen_sections = Index::Section.where(visibility: "groups").where.missing(:section_groups).ordered
    @unseen_entries = Index::Entry.where(app_id: nil, visibility: "groups").where.missing(:entry_groups).ordered
    @unseen_doc_sections = Index::DocSection.where(visibility: "groups").where.missing(:doc_section_groups).ordered
    @no_staff_group = !Group.staff.exists?
    @apps_without_entry = App.in_launcher.where.not(slug: Index::APP_SLUG).where.not(id: Index::Entry.where.not(app_id: nil).select(:app_id)).ordered
    @recent = (Index::Entry.order(updated_at: :desc).limit(8).to_a + Index::Doc.order(updated_at: :desc).limit(8).to_a)
                .sort_by(&:updated_at).reverse.first(8)
  end
end
