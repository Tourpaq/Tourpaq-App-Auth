# Ends one of the user's own sessions (SPECS.md §3.3): an auth-host sign-in or an index-host session.
# Ending the index session of this browser signs out here.
class Index::Profile::SessionsController < Index::BaseController
  def destroy
    row = current_user.sessions.active.where(kind: %w[home index]).find(params[:id])
    current = row == Current.session
    AuditEvent.record("session.ended", subject: current_user, data: { session_id: row.id, kind: row.kind, by: "user", current: current })
    if current
      end_index_session("ended_by_user")
      reset_session
      redirect_to index_signed_out_path
    else
      row.end!("ended_by_user")
      redirect_to index_profile_path, notice: "The session on #{row.browser_label} is ended."
    end
  end
end
