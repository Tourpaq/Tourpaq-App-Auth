# Ends one session (auth, index or admin) of a user from their admin page (SPECS.md §3.3, §11.2).
class Admin::UserSessionsController < Admin::BaseController
  def destroy
    user = User.find(params[:user_id])
    row = user.sessions.active.find(params[:id])
    row.end!("ended_by_admin")
    AuditEvent.record("session.ended", subject: user, data: { session_id: row.id, kind: row.kind, by: "admin" })
    if row == Current.session
      Current.session = nil
      redirect_to admin_root_path
    else
      redirect_to admin_user_path(user), notice: "The #{row.kind} session on #{row.browser_label} is ended."
    end
  end
end
