# The index's front page (SPECS.md §11.1, §24.3), WWW's front page for the signed-in user:
#
# - the personal tokens that expire within 7 days (§9.1) and, for admins, a link to the admin host;
# - "Your apps": every auth app the user has access to (shown in the launcher), with their role, so nothing of the old
#   launcher is lost (the index app itself is left out: it is this site). An app with a visible entry is shown as that
#   entry's card, which is then not repeated in its section below;
# - every visible "cards" section with its other visible entries as cards;
# - the visible entries in no section;
# - tiles leading to the visible "table" sections and to the visible docs.
#
# Someone who is not staff (a customer, a contractor) sees "Your apps" and only what is shown to their groups.
# A pending user never gets here (IndexAuthentication sends them to "waiting for access").
class Index::HomeController < Index::ContentController
  def show
    entries = visible_entries.ordered.to_a
    @apps = index_viewer.your_apps(entries)
    in_your_apps = @apps.grep(Index::Entry).map(&:id).to_set
    @card_sections = visible_sections.cards.ordered.to_a
    @entries_by_section = entries.reject { in_your_apps.include?(_1.id) }.group_by(&:section_id)
    @unsectioned = @entries_by_section.fetch(nil, [])
    @expiring_tokens = current_user.personal_tokens.expiring_soon.includes(:app).order(:expires_at).to_a
  end
end
