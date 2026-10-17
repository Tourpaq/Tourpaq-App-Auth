module ApplicationHelper
  DEFAULT_TIME_ZONE = "Europe/Copenhagen"

  def nav_link(text, path, count: nil)
    active = current_page?(path) rescue false
    active ||= path != "/" && request.path.start_with?(path)
    link_to path, class: "nav-item#{' active' if active}" do
      safe_join([ text, (tag.span(count, class: "nav-count") if count.to_i.positive?) ].compact, " ")
    end
  end

  # A time in Europe/Copenhagen ("15 Oct 2026 21:49"); the UTC time is in the tooltip.
  def local_time(time, format: :long)
    return tag.span("—", class: "muted") if time.nil?
    local = time.in_time_zone(viewer_time_zone)
    text = case format
           when :long then local.strftime("%-d %b %Y %H:%M")
           when :short then local.strftime("%-d %b %H:%M")
           when :date then local.strftime("%-d %b %Y")
           when :time then local.strftime("%H:%M")
           else I18n.l(local, format: format)
           end
    tag.time(text, datetime: time.utc.iso8601, title: time.utc.strftime("%Y-%m-%d %H:%M UTC"))
  end

  def relative_time(time)
    return tag.span("—", class: "muted") if time.nil?
    text = time.future? ? "in #{time_ago_in_words(time)}" : "#{time_ago_in_words(time)} ago"
    tag.time(text, datetime: time.utc.iso8601, title: time.in_time_zone(viewer_time_zone).strftime("%-d %b %Y %H:%M %Z"))
  end

  # A role key (or AppRole, or EffectiveRole result) as a badge; "no access" when nil. A multiple-roles
  # result (SPECS.md §23.2) is one badge per held role.
  def role_badge(role)
    if role.is_a?(EffectiveRole::Result) && role.multiple?
      return tag.span("no access", class: "badge role-none") unless role.access?
      return tag.span(safe_join(role.held.map { role_badge(_1.role) }, " "), class: "badge-list")
    end
    key = role.respond_to?(:role_key) ? role.role_key : role.respond_to?(:key) ? role.key : role
    return tag.span("no access", class: "badge role-none") if key.blank?
    tag.span(key, class: "badge role-#{key.to_s.parameterize}")
  end

  # "responder, from RO Dev" with the role as a badge. Multiple roles: one line per role with its sources
  # ("Support  from RO Dev, direct").
  def effective_role_label(result)
    return tag.span(result.to_s, class: "muted") unless result.access?
    if result.multiple?
      return tag.ul(class: "held-roles") do
        safe_join(result.held.map { |held| tag.li(safe_join([ role_badge(held.role), tag.span(held.sources_text, class: "muted small") ], " ")) })
      end
    end
    safe_join([ role_badge(result), tag.span(result.direct? ? "direct" : "from #{result.source}", class: "muted small") ], " ")
  end

  # A multiple-roles result's resolved permissions with their sources, folded ("12 permissions"):
  # "module:customers:view  from Support (via RO Dev), Management (direct)". "*" reads "everything".
  def permissions_details(result)
    return tag.span("—", class: "muted") unless result.multiple? && result.access?
    sources = result.permission_sources
    return tag.span("none", class: "muted small") if sources.empty?
    summary = result.permissions.include?(AppRole::WILDCARD) ? "everything (*)" : pluralize(sources.size, "permission")
    tag.details(class: "permissions") do
      safe_join([
        tag.summary(summary),
        tag.ul(class: "permission-list") do
          safe_join(sources.map do |key, held|
            via = held.map { |h| "#{h.key} (#{h.sources.map { _1 == 'direct' ? 'via direct grant' : "via #{_1}" }.join(', ')})" }
            tag.li(safe_join([ tag.code(key == AppRole::WILDCARD ? "* (everything)" : key), " ", tag.span("from #{via.join('; ')}", class: "muted") ]))
          end)
        end
      ])
    end
  end

  # A token scope for people: read / read and write; other apps' scopes (public, all) as they are.
  def token_scope_label(scope)
    { "read" => "read only", "read_write" => "read and write" }.fetch(scope.to_s, scope.to_s)
  end

  # Links across the hosts (SPECS.md §24.1).
  def admin_host_url(path = "/") = "#{AuthHosts.admin_url}#{path}"
  def index_host_url(path = "/") = "#{AuthHosts.index_url}#{path}"
  def auth_host_url(path = "/") = "#{AuthHosts.auth_url}#{path}"

  private

  def viewer_time_zone = ActiveSupport::TimeZone[DEFAULT_TIME_ZONE]
end
