# Sign out of the admin host (its own session only; the auth and index sessions are untouched).
class Admin::SessionsController < Admin::BaseController
  allow_unauthenticated_admin_access only: :destroy

  def destroy
    if (row = Session.find_by_plain(cookies.signed[AdminAuthentication::COOKIE], kind: "admin"))
      AuditEvent.record("auth.logout", subject: row.user, actor: row.user, data: { session_id: row.id, kind: "admin" })
      Current.session = row
    end
    end_admin_session("signed_out")
    reset_session
    render "admin/sessions/signed_out"
  end
end
