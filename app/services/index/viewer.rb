# Who is looking at the index (SPECS.md §24.3): the signed-in user, their auth groups, whether they are Tourpaq staff
# and the apps they have access to, with their effective role(s). The visibility scopes (Index::Section.visible_to,
# Index::Entry.visible_to, Index::DocSection.visible_to, Index::Doc.visible_to) take one. For nil or a disabled user
# there are no groups, no apps and no staff, so nothing matches.
#
#   viewer = Index::Viewer.new(current_user)
#   viewer.group_ids         # [1, 3]
#   viewer.staff?            # an admin, or a member of a staff group: sees the content for all staff ("everyone")
#   viewer.app_ids           # the active apps the user has a role in
#   viewer.access_for(app)   # the EffectiveRole::Result, or nil without access
#   viewer.apps_without_entry(tied_app_ids)  # the API's "your-apps": those apps that no visible entry stands for
#   viewer.your_apps(entries)  # "Your apps": [entry or EffectiveRole::Result] for every app in the launcher the user
#                              # has access to (never the index app itself), its visible entries when it has any
class Index::Viewer
  attr_reader :user

  def initialize(user)
    @user = user
  end

  def active? = user.present? && user.active?

  def group_ids
    @group_ids ||= active? ? user.group_memberships.pluck(:group_id) : []
  end

  def staff?
    return @staff if defined?(@staff)
    @staff = active? && (user.admin? || Group.staff.where(id: group_ids).exists?)
  end

  # app id => EffectiveRole::Result, for every active app the user has access to.
  def access
    @access ||= active? ? EffectiveRole.apps_for(user).index_by { _1.app.id } : {}
  end

  def app_ids = access.keys
  def access_for(app) = app && access[app.id]

  # For the API's "your-apps" group: the launcher apps the user has access to that no visible entry stands for.
  def apps_without_entry(tied_app_ids)
    tied = tied_app_ids.to_set
    launcher_access.reject { tied.include?(_1.app.id) }
  end

  # The launcher apps the user has access to, by app name; an app with visible entries (`entries`, already filtered
  # by visible_to) is shown as those entries, any other as the app itself.
  def your_apps(entries)
    by_app = entries.select(&:app_id).group_by(&:app_id)
    launcher_access.flat_map { |result| by_app.fetch(result.app.id, [ result ]) }
  end

  private

  def launcher_access
    access.values.select { |result| result.app.show_in_launcher? && result.app.slug != Index::APP_SLUG }
  end
end
