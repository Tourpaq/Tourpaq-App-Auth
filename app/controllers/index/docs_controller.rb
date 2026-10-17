# A documentation page, /docs/:section/:slug or /docs/:slug (WWW's paths). Docs are for everyone signed in.
class Index::DocsController < Index::ContentController
  def show
    section = params[:section] && Index::DocSection.find_by!(key: params[:section])
    @doc = Index::Doc.find_by!(doc_section: section, slug: params[:slug])
    @body = Index::Markdown.render(@doc.body)
  end
end
