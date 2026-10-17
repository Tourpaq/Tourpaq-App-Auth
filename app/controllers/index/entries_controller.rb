# An entry's details page, /apps/:slug (WWW's path): the facts, the links and the markdown body. An entry the viewer
# may not see (another app's, another group's, or in a hidden section) is a 404, as an unknown one.
class Index::EntriesController < Index::ContentController
  def show
    @entry = visible_entries.find_by!(slug: params[:id])
    @body = Index::Markdown.render(@entry.body)
  end
end
