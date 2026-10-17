# Sign out on the index host (SPECS.md §3.3, §24.1): ends the index session, then the auth session behind
# it through the auth host's RP-initiated logout (/oauth/logout with an id_token_hint for this user as client
# "index", so it needs no confirmation; the hint carries no identity claims but sub, Oidc::IdToken.issue_hint),
# which comes back to /signed_out here. The Microsoft session stays.
class Index::SessionsController < Index::BaseController
  allow_unauthenticated_index_access

  def destroy
    if (row = Session.find_by_plain(cookies.signed[IndexAuthentication::COOKIE], kind: "index"))
      AuditEvent.record("auth.logout", subject: row.user, actor: row.user, data: { session_id: row.id, kind: "index" })
      Current.session = row
      hint = Oidc::IdToken.issue_hint(user: row.user, client: Client.index_client)
    end
    end_index_session("signed_out")
    reset_session
    query = { client_id: Client::INDEX_CLIENT_ID, post_logout_redirect_uri: "#{AuthHosts.index_url}/signed_out", id_token_hint: hint }.compact
    redirect_to "#{AuthHosts.auth_url}/oauth/logout?#{query.to_query}", allow_other_host: true
  end

  def signed_out
    return redirect_to(index_root_path) if resume_index_session
  end
end
