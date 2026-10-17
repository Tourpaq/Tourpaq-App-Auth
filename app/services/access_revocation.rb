# "Remove access to one app" (SPECS.md §6): the user's OAuth tokens for that app are revoked.
# The admin UI revokes them when it changes a grant or a membership (AccessChange); the protocol
# refuses them anyway while there is no access (refresh, introspection and userinfo check the
# effective role on every use). This is the hourly sweep behind both (CleanupJob), for changes that
# happen elsewhere (an app disabled, a role removed, a console change), so access coming back later
# does not revive an old sign-in.
#
#   AccessRevocation.call(users: [user], app: app)   # number of tokens revoked
#   AccessRevocation.call                            # every live OAuth token (the sweep)
module AccessRevocation
  module_function

  def call(users: nil, app: nil)
    scope = OauthToken.active.joins(:client).where.not(clients: { app_id: nil })
    scope = scope.where(user_id: Array(users).map { _1.respond_to?(:id) ? _1.id : _1 }) if users
    scope = scope.where(clients: { app_id: app.id }) if app
    pairs = scope.distinct.pluck(:user_id, Arel.sql("clients.app_id"))
    users_by_id = User.where(id: pairs.map(&:first)).index_by(&:id)
    apps_by_id = App.where(id: pairs.map(&:last)).index_by(&:id)

    pairs.sum do |user_id, app_id|
      next 0 if EffectiveRole.for(users_by_id[user_id], apps_by_id[app_id]).access?
      OauthToken.active.where(user_id: user_id, client_id: Client.where(app_id: app_id).select(:id))
                .update_all(revoked_at: Time.current, updated_at: Time.current)
    end
  end
end
