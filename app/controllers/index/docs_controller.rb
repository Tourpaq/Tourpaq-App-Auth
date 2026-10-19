# A documentation page, /docs/:section/:slug or /docs/:slug (WWW's paths). Only a doc the viewer may see
# (Index::Doc.visible_to: its doc section's visibility); any other is a 404, like an unknown one.
class Index::DocsController < Index::ContentController
  def show
    section = params[:section] && Index::DocSection.find_by!(key: params[:section])
    @doc = Index::Doc.visible_to(index_viewer).find_by!(doc_section: section, slug: params[:slug])
    @body = Index::Markdown.render(@doc.body)
  end
end
