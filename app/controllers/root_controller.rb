# The auth host's "/" (SPECS.md §24.1): nothing lives here. A signed-in user goes on to the index host, or
# to "waiting for access" while they have no access at all; anybody else to the sign-in page.
class RootController < ApplicationController
  allow_unauthenticated_access

  def show
    return redirect_to(sign_in_path) unless resume_session
    return redirect_to(waiting_path) if current_user.pending?
    redirect_to "#{AuthHosts.index_url}/", allow_other_host: true
  end
end
