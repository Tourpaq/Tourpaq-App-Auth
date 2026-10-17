# Entries of the index (WWW's apps) on the admin host: list by section, add, edit with links (add, remove, order),
# tie to an auth app or set the visibility, delete. Audited index.entry.created / updated / deleted.
class Admin::IndexContent::EntriesController < Admin::IndexContent::BaseController
  before_action :set_entry, only: %i[edit update destroy]

  def index
    @entries = Index::Entry.includes(:section, :access_level, :login_method, :app, :groups).ordered
    @by_section = @entries.group_by(&:section).sort_by { |section, _| section ? [ section.table? ? 1 : 0, section.position, section.name ] : [ 2, 0, "" ] }
  end

  # ?app_id= (from the overview's "apps without an entry") starts the entry from the app.
  def new
    app = App.find_by(id: params[:app_id])
    @entry = Index::Entry.new(section_id: params[:section_id], app: app, name: app&.name, description: app&.description, url: app&.url)
  end

  def create
    @entry = Index::Entry.new(entry_params)
    if @entry.save
      audit("entry.created", @entry, { slug: @entry.slug, name: @entry.name, app: @entry.app&.slug, visibility: @entry.visibility,
                                       groups: @entry.groups.map(&:name), links: link_list(@entry.links) }.compact)
      redirect_to edit_admin_index_entry_path(@entry), notice: "“#{@entry.name}” added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit; end

  def update
    links_before = link_list(@entry.links)
    groups_before = @entry.groups.map(&:name).sort
    if update_atomically(@entry, entry_params)
      changes = audited_changes(@entry)
      links_after = link_list(@entry.links.reload)
      groups_after = @entry.groups.reload.map(&:name).sort
      changes["links"] = [ links_before, links_after ] if links_after != links_before
      changes["groups"] = [ groups_before, groups_after ] if groups_after != groups_before
      audit("entry.updated", @entry, { slug: @entry.slug, changes: changes }) if changes.any?
      redirect_to edit_admin_index_entry_path(@entry), notice: "“#{@entry.name}” saved."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @entry.destroy!
    audit("entry.deleted", @entry, { slug: @entry.slug, name: @entry.name })
    redirect_to admin_index_entries_path, notice: "“#{@entry.name}” deleted."
  end

  private

  def set_entry
    @entry = Index::Entry.find_by!(slug: params[:id])
  end

  def link_list(links) = links.reject(&:marked_for_destruction?).map { "#{_1.label} #{_1.url}" }

  def entry_params
    permitted = params.require(:index_entry).permit(
      :name, :slug, :description, :url, :address, :section_id, :app_id, :visibility, :status, :owner, :repo, :icon,
      :access_level_id, :login_method_id, :position, :body, group_ids: [],
      links_attributes: %i[id label url note position _destroy]
    )
    permitted[:group_ids] = Array(permitted[:group_ids]).compact_blank if permitted.key?(:group_ids)
    permitted
  end
end
