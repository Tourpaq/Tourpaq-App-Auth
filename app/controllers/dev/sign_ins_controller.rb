# The fake identity provider (SPECS.md §3.4), development and test only (config/routes/dev.rb is
# not drawn otherwise, and this checks again). Pick a user or type an email and name: it produces
# the same auth hash as Entra and goes through the same sign-in code.
class Dev::SignInsController < ApplicationController
  allow_unauthenticated_access
  before_action { head :not_found unless FakeIdentity.enabled? }

  def new
    @users = User.ordered.limit(50)
  end

  def create
    email = params[:email].to_s.strip
    return redirect_to(dev_sign_in_path, alert: "Enter an email address.") if email.blank?
    sign_in_from_entra(FakeIdentity.auth_hash(email: email, name: params[:name].presence,
                                              tid: params[:tid].presence || FakeIdentity.tenant_id))
  end
end
