# Small view helpers for the launcher, profile and admin pages (SPECS.md §11). The CSP forbids
# inline style attributes: icons are inline SVG with presentation attributes, colours come from CSS.
module UiHelper
  # Outline icons (24×24, stroke) for apps' `icon` names; seeds use bell, chart, logs, cost, home.
  APP_ICONS = {
    "bell" => "M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9 M10.3 21a1.94 1.94 0 0 0 3.4 0",
    "chart" => "M3 3v18h18 M7 16v-5 M12 16V8 M17 16v-9",
    "logs" => "M4 6h16 M4 10h16 M4 14h10 M4 18h7",
    "cost" => "M12 2v20 M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6",
    "home" => "M3 10.5 12 3l9 7.5V21h-6v-6H9v6H3z",
    "key" => "M15.5 7.5a4 4 0 1 1-3.9 4.9L3 21v-3l1-1h2v-2h2l2.4-2.4 M17 7h.01",
    "shield" => "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z",
    "users" => "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8 M22 21v-2a4 4 0 0 0-3-3.87 M16 3.13a4 4 0 0 1 0 7.75",
    "globe" => "M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20 M2 12h20 M12 2a15 15 0 0 1 0 20 15 15 0 0 1 0-20"
  }.freeze

  # The app's icon: a known icon name as SVG, a short text (an emoji) as is, else its initials.
  def app_icon(app, css: "app-icon")
    name = app.icon.to_s.strip
    if (path = APP_ICONS[name.downcase])
      tag.span(class: css, "aria-hidden": true) do
        tag.svg(viewBox: "0 0 24 24", width: 24, height: 24, fill: "none", stroke: "currentColor",
                "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round") { tag.path(d: path) }
      end
    elsif name.present? && name.length <= 4
      tag.span(name, class: css, "aria-hidden": true)
    else
      tag.span(app.name.to_s.split(/\s+/).first(2).map { _1[0] }.join.upcase, class: "#{css} app-icon-initials", "aria-hidden": true)
    end
  end

  # Pending / disabled / admin / not signed in yet, as pills.
  def user_status_pills(user, pending_ids: nil)
    pending = pending_ids ? pending_ids.include?(user.id) : user.pending?
    pills = []
    pills << tag.span("disabled", class: "pill pill-bad") if user.disabled?
    pills << tag.span("pending", class: "pill pill-warn") if pending
    pills << tag.span("admin", class: "badge role-admin") if user.admin?
    pills << tag.span("not signed in yet", class: "pill pill-muted") unless user.bound?
    safe_join(pills, " ")
  end

  # An expiry as a pill: expired, expiring soon (within `warn`), or the date.
  def expiry_pill(time, warn:)
    return tag.span("never expires", class: "pill pill-muted") if time.nil?
    if time <= Time.current
      tag.span(safe_join([ "expired ", local_time(time, format: :date) ]), class: "pill pill-bad")
    elsif time <= warn.from_now
      tag.span(safe_join([ "expires ", relative_time(time) ]), class: "pill pill-warn")
    else
      tag.span(safe_join([ "expires ", local_time(time, format: :date) ]), class: "pill pill-muted")
    end
  end

  # The Entra client secret's expiry (§14): a warning from 30 days before ENTRA_CLIENT_SECRET_EXPIRES_ON.
  ENTRA_SECRET_WARN_DAYS = 30

  def entra_secret_warning
    expires_on = Rails.configuration.x.auth.entra_client_secret_expires_on
    return if expires_on.nil?
    days = (expires_on - Time.current.in_time_zone(ApplicationHelper::DEFAULT_TIME_ZONE).to_date).to_i
    return if days > ENTRA_SECRET_WARN_DAYS
    if days.negative?
      [ :bad, "The Entra client secret expired on #{expires_on.strftime('%-d %b %Y')}: nobody can sign in to any app. Create a new secret in Entra and set ENTRA_CLIENT_SECRET and ENTRA_CLIENT_SECRET_EXPIRES_ON." ]
    else
      when_text = days.zero? ? "today" : "in #{days} #{'day'.pluralize(days)}"
      [ :warn, "The Entra client secret expires #{when_text} (#{expires_on.strftime('%-d %b %Y')}). When it expires nobody can sign in to any app: create a new one in Entra and update ENTRA_CLIENT_SECRET and ENTRA_CLIENT_SECRET_EXPIRES_ON." ]
    end
  end

  # What an audit event is about: a link to the user, group or app when it still exists.
  def audit_subject_label(event)
    subject = event.subject
    case subject
    when User then link_to(subject.display_name, admin_user_path(subject))
    when Group then link_to(subject.name, admin_group_path(subject))
    when App then link_to(subject.name, admin_app_path(subject))
    when Client then subject.app ? link_to(subject.client_id, admin_app_client_path(subject.app, subject)) : subject.client_id
    when PersonalToken then "token #{subject.name} (#{subject.token_hint}…)"
    when Index::Entry then link_to("index entry #{subject.name}", edit_admin_index_entry_path(subject))
    when Index::Section then link_to("index section #{subject.name}", edit_admin_index_section_path(subject))
    when Index::Doc then link_to("index doc #{subject.title}", edit_admin_index_doc_path(subject))
    when nil then event.subject_type ? tag.span("#{event.subject_type} ##{event.subject_id} (deleted)", class: "muted") : ""
    else "#{event.subject_type} ##{event.subject_id}"
    end
  end
end
