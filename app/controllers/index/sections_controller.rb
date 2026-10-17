# One section of the index, /groups/:slug (WWW's path): cards, or a compact filterable table for a "table" section.
# A section the viewer may not see is a 404, as an unknown one.
class Index::SectionsController < Index::ContentController
  def show
    @section = visible_sections.find_by!(slug: params[:id])
    @entries = visible_entries.where(section: @section).ordered.to_a
  end
end
