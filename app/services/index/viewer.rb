# Who is looking at the index (SPECS.md §24.3): the signed-in user, their auth groups and the apps they have access
# to, with their effective role(s). The visibility scopes (Index::Section.visible_to, Index::Entry.visible_to) take
# one. For nil or a disabled user there are no groups and no apps, so only what is for everyone signed in matches.
#
#   viewer = Index::Viewer.new(current_user)
#   viewer.group_ids         # [1, 3]
#   viewer.app_ids           # the active apps the user has a role in
#   viewer.access_for(app)   # the EffectiveRole::Result, or nil without access
#   viewer.apps_without_entry(tied_app_ids)   # "Your apps": EffectiveRole::Results for the apps in the launcher that
#                                             # no entry stands for (never the index app itself)
class Index::Viewer
  attr_reader :user

  def initialize(user)
    @user = user
  end

  def active? = user.present? && user.active?

  def group_ids
    @group_ids ||= active? ? user.group_memberships.pluck(:group_id) : []
  end

  # app id => EffectiveRole::Result, for every active app the user has access to.
  def access
    @access ||= active? ? EffectiveRole.apps_for(user).index_by { _1.app.id } : {}
  end

  def app_ids = access.keys
  def access_for(app) = app && access[app.id]

  def apps_without_entry(tied_app_ids)
    tied = tied_app_ids.to_set
    access.values.select { |result| result.app.show_in_launcher? && result.app.slug != Index::APP_SLUG && !tied.include?(result.app.id) }
  end
end
