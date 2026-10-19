# GET /api/v1/index on the INDEX host (SPECS.md §24.3): the viewer's whole index in one document, for the browser
# extension's side panel (clients/index-extension). Read-only and versioned: the panel filters and searches it locally.
#
# Who is asking:
# - the extension: `Authorization: Bearer tpx_index_…`, its access token as client index-extension, checked in-process
#   with the rules of /oauth/introspect (Index::ExtensionToken);
# - a browser signed in on the index host (the index_session cookie).
# Anything else is 401 (`WWW-Authenticate: Bearer`), a pending user 403. The answer holds only what that user may see
# (the same queries as the web pages), so it is `Cache-Control: private, no-store`.
#
# WWW's response shape, unchanged (fields may be added, never renamed or removed without bumping VERSION; the panel may
# be an old version on somebody's machine). Added: per group `visibility`; per app `app` (the auth app's slug),
# `role` and `roles` (the viewer's role(s) in it), `visibility`. "Your apps" (auth apps without a visible entry; the front
# page also moves the apps' entries there) is the first group (slug "your-apps"). Every URL is absolute, on INDEX_URL (never the Host header).
class Index::Api::IndexController < Index::BaseController
  VERSION = 1

  allow_unauthenticated_index_access
  before_action :authenticate_index_api

  def show
    response.headers["Cache-Control"] = "private, no-store"
    entries = Index::Entry.visible_to(viewer).includes(:section, :access_level, :login_method, :links, :app).ordered.to_a
    by_section = entries.group_by(&:section_id)
    sections = Index::Section.visible_to(viewer).menu_order.to_a

    groups = []
    apps = viewer.apps_without_entry(entries.filter_map(&:app_id))
    if apps.any?
      groups << { name: "Your apps", slug: "your-apps", audience: "everyone", description: "The apps you have access to.",
                  url: absolute("/"), visibility: "apps", apps: apps.map { app_only_json(_1) } }
    end
    sections.each do |section|
      members = by_section[section.id] or next
      groups << group_json(section.name, section.slug, section.audience, section.description,
                           absolute(index_section_path(section)), section.visibility, members)
    end
    if (loose = by_section[nil])
      groups << group_json("Not yet in a group", nil, "everyone", nil, nil, "everyone", loose)
    end

    render json: {
      version: VERSION,
      site: { title: site.title, brand: site.brand_or_title, url: absolute("/") },
      updated_at: last_updated_at&.iso8601,
      groups: groups,
      docs: Index::Doc.visible_to(viewer).includes(:doc_section).ordered.map { |doc| doc_json(doc) }
    }
  end

  private

  def viewer = @viewer ||= Index::Viewer.new(@api_user)
  def site = @site ||= Index::Site.current

  def authenticate_index_api
    bearer = request.authorization.to_s[/\ABearer\s+(\S+)\z/i, 1]
    @api_user = bearer ? Index::ExtensionToken.user_for(bearer) : resume_index_session && current_user
    unless @api_user&.active?
      response.headers["WWW-Authenticate"] = %(Bearer realm="#{AuthHosts.index_url}"#{', error="invalid_token"' if bearer})
      # Where the extension signs in (clients/index-extension reads this before its first sign-in).
      return render(json: { error: "unauthorized", message: "Sign in to the index (or the extension) first.",
                            auth: { issuer: AuthHosts.auth_url, client_id: Index::EXTENSION_CLIENT_ID, scope: "openid email profile offline_access" } },
                    status: :unauthorized)
    end
    render(json: { error: "pending", message: "You have no access yet. An admin has been told." }, status: :forbidden) if @api_user.pending?
  end

  def last_updated_at
    [ Index::Entry.maximum(:updated_at), Index::Doc.maximum(:updated_at), Index::Section.maximum(:updated_at), site.updated_at ].compact.max
  end

  def group_json(name, slug, audience, description, url, visibility, entries)
    { name: name, slug: slug, audience: audience, description: description, url: url, visibility: visibility,
      apps: entries.map { |entry| entry_json(entry) } }
  end

  def entry_json(entry)
    access = viewer.access_for(entry.app)
    {
      name: entry.name,
      description: entry.description,
      status: entry.status,
      url: absolute(entry.url),
      page_url: (absolute(index_entry_path(entry)) if entry.page?),
      details_url: absolute(index_entry_path(entry)),
      address: entry.address,
      owner: entry.owner,
      repo: absolute(entry.repo),
      icon: (entry.icon unless entry.icon_url?),
      icon_url: (absolute(entry.icon) if entry.icon_url?),
      initials: entry.initials,
      # nil, not omitted: the panel shows an unset value as a dashed pill.
      access: marker_json(entry.access_level),
      login: marker_json(entry.login_method),
      links: entry.links.map { |link| { label: link.label, url: absolute(link.url), note: link.note } },
      app: entry.app&.slug,
      role: access&.role_key,
      roles: access ? access.role_keys : [],
      visibility: entry.app ? "app" : entry.visibility
    }
  end

  # An auth app the viewer has access to that no entry stands for ("Your apps").
  def app_only_json(access)
    app = access.app
    { name: app.name, description: app.description.to_s, status: "live", url: app.url.presence, page_url: nil, details_url: nil,
      address: nil, owner: nil, repo: nil, icon: nil, icon_url: nil, initials: helpers.index_initials(app.name),
      access: nil, login: { label: "Tourpaq sign-in", tone: "ok" }, links: [], app: app.slug, role: access.role_key, roles: access.role_keys, visibility: "app" }
  end

  def marker_json(marker)
    marker && { label: marker.label, tone: marker.tone }
  end

  def doc_json(doc)
    { title: doc.title, summary: doc.summary, section: doc.doc_section&.title, url: absolute(doc.path) }
  end

  def absolute(url)
    url&.start_with?("/") ? "#{AuthHosts.index_url}#{url}" : url
  end
end
