# Signs out one of a user's browser extensions from their admin page (SPECS.md §10.6).
class Admin::UserExtensionsController < Admin::BaseController
  def destroy
    user = User.find(params[:user_id])
    token = ExtensionSignIns.find_for(user, params[:id])
    ExtensionSignIns.revoke!(token, by: "admin")
    redirect_to admin_user_path(user), notice: "#{token.client.name.presence || token.client.client_id} is signed out for #{user.display_name}."
  end
end
