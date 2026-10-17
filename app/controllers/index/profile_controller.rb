# The user's own page (SPECS.md §11.1), on the index host: name and email from Entra (read-only), access per
# app and where it comes from, the user's sessions at the auth host (the Entra sign-ins) and at the index host
# (end one), and signed-in browser extensions (sign one out). Personal tokens have their own page, /tokens (§9.1).
class Index::ProfileController < Index::BaseController
  def show
    @user = current_user
    @access = EffectiveRole.apps_for(@user)
    @sessions = @user.sessions.active.where(kind: %w[home index]).recent_first.to_a
    @extensions = ExtensionSignIns.for(@user)
  end
end
