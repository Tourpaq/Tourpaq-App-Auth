# Dev-only stand-in for the admin host's OIDC sign-in (SPECS.md §11.2), until the protocol
# milestone implements AdminAuthentication#start_admin_sign_in. Development and test only.
class Dev::AdminSignInsController < Admin::BaseController
  allow_unauthenticated_admin_access
  before_action { head :not_found unless FakeIdentity.enabled? }

  def new
    @users = User.active.admins.ordered
  end

  def create
    user = User.find_by_email(params[:email])
    complete_admin_sign_in(user, authenticated_at: Time.current)
  end
end
