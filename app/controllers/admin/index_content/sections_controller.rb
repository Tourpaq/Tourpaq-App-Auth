# Sections of the index (WWW's groups) on the admin host: name, layout (cards on the front page, or a table page),
# visibility (all Tourpaq staff, or the chosen auth groups), order. Deleting keeps the entries, without a section.
# Audited index.section.created / updated / deleted.
class Admin::IndexContent::SectionsController < Admin::IndexContent::BaseController
  before_action :set_section, only: %i[edit update destroy]

  def index
    @sections = Index::Section.includes(:groups).menu_order.to_a
    @counts = Index::Entry.group(:section_id).count
  end

  def new
    @section = Index::Section.new(layout: params[:layout].presence_in(Index::Section::LAYOUTS) || "cards")
  end

  def create
    @section = Index::Section.new(section_params)
    if @section.save
      audit("section.created", @section, { slug: @section.slug, name: @section.name, layout: @section.layout,
                                           visibility: @section.visibility, groups: @section.groups.map(&:name) })
      redirect_to admin_index_sections_path, notice: "Section “#{@section.name}” added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit; end

  def update
    groups_before = @section.groups.map(&:name).sort
    if update_atomically(@section, section_params)
      changes = audited_changes(@section)
      groups_after = @section.groups.reload.map(&:name).sort
      changes["groups"] = [ groups_before, groups_after ] if groups_after != groups_before
      audit("section.updated", @section, { slug: @section.slug, changes: changes }) if changes.any?
      redirect_to admin_index_sections_path, notice: "Section “#{@section.name}” saved."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    entries = @section.entries.count
    @section.destroy!
    audit("section.deleted", @section, { slug: @section.slug, name: @section.name, entries: entries })
    redirect_to admin_index_sections_path, notice: "Section “#{@section.name}” deleted. Its entries are now without a section."
  end

  private

  def set_section
    @section = Index::Section.find_by!(slug: params[:id])
  end

  def section_params
    permitted = params.require(:index_section).permit(:name, :slug, :description, :layout, :visibility, :position, group_ids: [])
    permitted[:group_ids] = Array(permitted[:group_ids]).compact_blank if permitted.key?(:group_ids)
    permitted[:group_ids] = [] if permitted[:visibility] == "everyone"
    permitted
  end
end
