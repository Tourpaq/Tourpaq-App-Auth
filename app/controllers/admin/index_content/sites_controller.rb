# The index's site settings on the admin host: title, brand, tagline, footer. Audited index.site.updated.
class Admin::IndexContent::SitesController < Admin::IndexContent::BaseController
  def edit
    @site = Index::Site.current
  end

  def update
    @site = Index::Site.current
    if @site.update(params.require(:index_site).permit(:title, :brand, :tagline, :footer))
      changes = audited_changes(@site)
      audit("site.updated", @site, { changes: changes }) if changes.any?
      redirect_to edit_admin_index_site_path, notice: "Site settings saved."
    else
      render :edit, status: :unprocessable_content
    end
  end
end
