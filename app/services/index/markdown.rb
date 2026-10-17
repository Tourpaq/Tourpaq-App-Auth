# Renders the index's markdown (entry details pages and docs), as WWW's Markdown.render did.
#
# GitHub-flavoured (tables, fenced code), highlighted with Rouge; headings get ids and a hover anchor, and h2/h3 are
# collected for the "On this page" table of contents. The output is sanitised: editors are not fully trusted, so raw
# HTML in the markdown must not be able to run script (SPECS.md §24.3).
#
#   result = Index::Markdown.render(text)
#   result.html   # safe HTML
#   result.toc    # [{ id:, name:, level: }]
module Index::Markdown
  Result = Data.define(:html, :toc)

  TAGS = %w[
    a abbr b blockquote br code dd del details div dl dt em h1 h2 h3 h4 h5 h6 hr i img
    kbd li mark ol p pre s small span strong sub summary sup table tbody td tfoot th thead tr u ul
  ].freeze
  ATTRIBUTES = %w[href src alt title id class colspan rowspan align start].freeze

  def self.render(text)
    return Result.new(html: "".html_safe, toc: []) if text.blank?

    html = Kramdown::Document.new(
      text,
      input: "GFM",
      hard_wrap: false,
      auto_ids: true,
      syntax_highlighter: "rouge",
      syntax_highlighter_opts: { css_class: "highlight", guess_lang: false }
    ).to_html
    html = Rails::HTML5::SafeListSanitizer.new.sanitize(html, tags: TAGS, attributes: ATTRIBUTES)

    fragment = Nokogiri::HTML5.fragment(html)
    toc = []
    fragment.css("h1, h2, h3, h4").each do |heading|
      next if heading["id"].blank?

      toc << { id: heading["id"], name: heading.text, level: heading.name[1].to_i } if %w[h2 h3].include?(heading.name)
      anchor = Nokogiri::XML::Node.new("a", fragment.document)
      anchor["class"] = "headerlink"
      anchor["href"] = "##{heading['id']}"
      anchor.content = "#"
      heading.add_child(anchor)
    end
    # Links that leave the site open as ordinary links but don't leak the referrer.
    fragment.css("a[href^='http']").each { |a| a["rel"] = "noreferrer" }

    Result.new(html: fragment.to_html.html_safe, toc: toc)
  end
end
