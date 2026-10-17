# The index's front page (SPECS.md §11.1, §24.3), WWW's front page for the signed-in user:
#
# - the personal tokens that expire within 7 days (§9.1) and, for admins, a link to the admin host;
# - "Your apps": the auth apps the user has access to (shown in the launcher) that no entry below stands for, with
#   their role, so nothing of the old launcher is lost (the index app itself is left out: it is this site);
# - every visible "cards" section with its visible entries as cards (an app's entry shows the user's role);
# - the visible entries in no section;
# - tiles leading to the visible "table" sections and to the docs.
#
# A pending user never gets here (IndexAuthentication sends them to "waiting for access").
class Index::HomeController < Index::ContentController
  def show
    entries = visible_entries.ordered.to_a
    @card_sections = visible_sections.cards.ordered.to_a
    @entries_by_section = entries.group_by(&:section_id)
    @unsectioned = @entries_by_section.fetch(nil, [])
    @apps = index_viewer.apps_without_entry(entries.filter_map(&:app_id))
    @expiring_tokens = current_user.personal_tokens.expiring_soon.includes(:app).order(:expires_at).to_a
  end
end
