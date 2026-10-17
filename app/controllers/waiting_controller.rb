# "Waiting for access" (SPECS.md §3.2, §11.1, §24.1), on the auth host: a signed-in user who has nothing
# yet (User#pending?). The index host sends such users here. Once they have access, this sends them on.
class WaitingController < ApplicationController
  def show
    redirect_to "#{AuthHosts.index_url}/", allow_other_host: true unless current_user.pending?
  end
end
