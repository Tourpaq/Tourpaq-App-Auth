# View helpers of the index content (SPECS.md §24.3), on the index host and on the admin host's index screens.
# Carried over from WWW's ApplicationHelper (icon tiles, the two pills, the status badge), with the auth app's roles.
#
# On the index host the layout's navigation calls index_site, index_menu_sections, index_doc_sections and
# index_last_updated_at; they need a signed-in viewer (index_viewer, from IndexAuthentication's current_user).
module Index::ContentHelper
  def index_site = @index_site ||= Index::Site.current
  def index_viewer = @index_viewer ||= Index::Viewer.new(current_user)

  # [[section, count]] for the sections the viewer may see, with the number of entries in it they may see; cards
  # first, then tables, as in WWW's menu.
  def index_menu_sections
    @index_menu_sections ||= begin
      counts = Index::Entry.visible_to(index_viewer).where.not(section_id: nil).group(:section_id).count
      Index::Section.visible_to(index_viewer).menu_order.map { |section| [ section, counts.fetch(section.id, 0) ] }
    end
  end

  def index_doc_sections
    @index_doc_sections ||= Index::DocSection.ordered.includes(:docs).select { |s| s.docs.any? }
  end

  def index_last_updated_at
    @index_last_updated_at ||= [ Index::Entry.maximum(:updated_at), Index::Doc.maximum(:updated_at),
                                 Index::Section.maximum(:updated_at), index_site.updated_at ].compact.max
  end

  # The icon tile: an entry's image or emoji or initials; an auth App's outline icon (UiHelper::APP_ICONS), emoji or
  # initials.
  def index_icon(record, size: nil)
    classes = [ "ix-icon", ("ix-icon-#{size}" if size) ]
    if record.is_a?(Index::Entry) && record.icon_url?
      tag.span(class: classes + [ "ix-icon-img" ]) do
        image_tag(record.icon, alt: "", loading: "lazy", referrerpolicy: "no-referrer")
      end
    elsif record.is_a?(App) && (path = UiHelper::APP_ICONS[record.icon.to_s.strip.downcase])
      tag.span(class: classes, "aria-hidden": true) do
        tag.svg(viewBox: "0 0 24 24", width: 24, height: 24, fill: "none", stroke: "currentColor",
                "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round") { tag.path(d: path) }
      end
    elsif record.icon.present? && record.icon.to_s.length <= 8
      tag.span(record.icon, class: classes)
    else
      tag.span(index_initials(record.name), class: classes + [ "ix-icon-initials" ])
    end
  end

  def index_initials(name)
    name.to_s.split(/[\s\-_]+/).reject(&:blank?).first(2).map { |w| w[0] }.join.upcase.presence || "?"
  end

  # How an entry is reached, or how you sign in. An unset value is shown rather than hidden: a blank on an access
  # overview is itself worth seeing.
  def index_marker_pill(marker, unset:, prefix:)
    if marker
      tag.span(marker.label, class: "ix-access ix-tone-#{marker.tone}", title: "#{prefix}: #{marker.label}")
    else
      tag.span(unset, class: "ix-access ix-tone-unset", title: "#{prefix} not recorded")
    end
  end

  def index_access_pills(entry)
    tag.div(class: "ix-pills") do
      index_marker_pill(entry.access_level, unset: "Access?", prefix: "Network access") +
        index_marker_pill(entry.login_method, unset: "Login?", prefix: "Login")
    end
  end

  def index_status_badge(entry)
    tag.span(entry.status, class: "ix-badge ix-badge-#{entry.status}")
  end

  # The viewer's role(s) in the entry's app, as the auth app's badges ("responder"), or nothing.
  def index_role(entry_or_app)
    app = entry_or_app.is_a?(App) ? entry_or_app : entry_or_app.app
    access = index_viewer.access_for(app) or return
    tag.div(class: "ix-card-role", title: "Your role in #{app.name}: #{access}") { role_badge(access) }
  end

  # Where a card's title goes: its own page when it has one, else straight out.
  def index_entry_href(entry)
    entry.page? ? index_entry_path(entry) : (safe_index_href(entry.primary_url) || index_entry_path(entry))
  end

  # An editor's URL as a link target, only when it is a web link or a site path (Index::URL_FORMAT; the models refuse
  # anything else, this is the second line), else nil.
  def safe_index_href(url)
    url.to_s if url.present? && Index::URL_FORMAT.match?(url.to_s)
  end

  def index_time_ago(time)
    return "never" unless time

    "#{time_ago_in_words(time)} ago"
  end

  def index_nav_class(active)
    active ? "nav-item ix-nav-item active" : "nav-item ix-nav-item"
  end
end
