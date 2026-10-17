# Signs out one of the user's browser extensions (SPECS.md §10.6): revokes its token chain.
class Index::Profile::ExtensionsController < Index::BaseController
  def destroy
    token = ExtensionSignIns.find_for(current_user, params[:id])
    ExtensionSignIns.revoke!(token, by: "user")
    redirect_to index_profile_path, notice: "#{token.client.name.presence || token.client.client_id} is signed out."
  end
end
