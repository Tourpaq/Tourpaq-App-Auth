# Doc sections of the index on the admin host: the documentation headings, and who sees their docs (all Tourpaq staff,
# or the chosen auth groups). Deleting keeps the docs, without a section (then for staff). Audited
# index.doc_section.created / updated / deleted.
class Admin::IndexContent::DocSectionsController < Admin::IndexContent::BaseController
  before_action :set_section, only: %i[edit update destroy]

  def index
    @sections = Index::DocSection.ordered.includes(:docs, :groups)
  end

  def new
    @section = Index::DocSection.new
  end

  def create
    @section = Index::DocSection.new(section_params)
    if @section.save
      audit("doc_section.created", @section, { key: @section.key, title: @section.title, visibility: @section.visibility,
                                               groups: @section.groups.map(&:name) })
      redirect_to admin_index_doc_sections_path, notice: "Section “#{@section.title}” added."
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
      audit("doc_section.updated", @section, { key: @section.key, changes: changes }) if changes.any?
      redirect_to admin_index_doc_sections_path, notice: "Section “#{@section.title}” saved."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @section.destroy!
    audit("doc_section.deleted", @section, { key: @section.key, title: @section.title })
    redirect_to admin_index_doc_sections_path, notice: "Section “#{@section.title}” deleted. Its docs are kept, without a section."
  end

  private

  def set_section
    @section = Index::DocSection.find(params[:id])
  end

  def section_params
    permitted = params.require(:index_doc_section).permit(:title, :key, :visibility, :position, group_ids: [])
    permitted[:group_ids] = Array(permitted[:group_ids]).compact_blank if permitted.key?(:group_ids)
    permitted[:group_ids] = [] if permitted[:visibility] == "everyone"
    permitted
  end
end
