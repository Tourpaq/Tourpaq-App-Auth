# Search (SPECS.md §24.3): the full results at /search?q=…, and /search.json, the viewer's whole index for the
# as-you-type box in the sidebar (fetched once per page, filtered in the browser). Both hold only what the viewer may
# see (Index::Entry.visible_to, Index::Doc.visible_to), so the JSON is private to the user and never stored by the browser.
class Index::SearchController < Index::ContentController
  def index
    respond_to do |format|
      format.html do
        @query = params[:q].to_s.strip
        @entries = visible_entries.search(@query).ordered.to_a
        @docs = search_docs(@query)
      end
      format.json do
        # Never stored: another user of the same browser must not get this viewer's index from the HTTP cache (the
        # sidebar keeps it in memory for the page, which is all the caching it needs). As /api/v1/index.
        response.headers["Cache-Control"] = "private, no-store"
        render json: search_index
      end
    end
  end

  private

  def search_docs(query)
    terms = query.downcase.split
    return [] if terms.empty?

    Index::Doc.visible_to(index_viewer).includes(:doc_section).ordered.select do |doc|
      text = [ doc.title, doc.summary, doc.body ].join(" ").downcase
      terms.all? { |term| text.include?(term) }
    end
  end

  def search_index
    entries = visible_entries.ordered.map do |entry|
      {
        name: entry.name, description: entry.description, group: entry.section&.name,
        href: helpers.index_entry_href(entry),
        address: entry.address, url: entry.url, owner: entry.owner,
        icon: entry.icon_url? ? nil : entry.icon, links: entry.links.map(&:label)
      }
    end
    docs = Index::Doc.visible_to(index_viewer).includes(:doc_section).ordered.map do |doc|
      { name: doc.title, description: doc.summary, group: "Docs", href: doc.path }
    end
    entries + docs
  end
end
