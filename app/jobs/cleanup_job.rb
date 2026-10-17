# Hourly (config/recurring.yml): removes what has no use any more, and ends what has run out.
# Personal tokens and audit events are kept (the token list shows revoked and expired ones; the audit
# log is kept indefinitely).
#
# - authorization codes an hour after they expired (they live 60 s);
# - home and admin sessions past their idle or absolute limit are ended (session.expired), so the
#   profile and the admin pages do not list them as live; ended sessions go after 30 days;
# - OAuth tokens of users who lost access to the app are revoked (AccessRevocation, §6);
#   expired or revoked OAuth tokens go after 30 days;
# - usage counts (per client and day) after 400 days.
class CleanupJob < ApplicationJob
  KEEP_ENDED_SESSIONS = 30.days
  KEEP_DEAD_OAUTH_TOKENS = 30.days
  KEEP_USAGE_COUNTS = 400.days

  def perform
    Current.set(channel: "system") do
      AuthorizationCode.where(expires_at: ...1.hour.ago).delete_all
      end_expired_sessions
      Session.where(ended_at: ...KEEP_ENDED_SESSIONS.ago).where.not(id: AuthorizationCode.select(:session_id)).delete_all
      AccessRevocation.call
      # Expired or revoked extension tokens; a successor's replaced_by link is cleared first.
      dead = OauthToken.where(expires_at: ...KEEP_DEAD_OAUTH_TOKENS.ago).or(OauthToken.where(revoked_at: ...KEEP_DEAD_OAUTH_TOKENS.ago))
      OauthToken.where(replaced_by_id: dead.select(:id)).update_all(replaced_by_id: nil)
      dead.delete_all
      UsageCount.where(day: ...KEEP_USAGE_COUNTS.ago.to_date).delete_all
    end
  end

  private

  def end_expired_sessions
    auth = Rails.configuration.x.auth
    idle = [ auth.session_idle, auth.admin_session_idle ].min.ago
    lifetime = [ auth.session_max, auth.admin_reauth ].min.ago
    candidates = Session.active.includes(:user).where(last_seen_at: ...idle).or(Session.active.includes(:user).where(entra_authenticated_at: ...lifetime))
    candidates.find_each do |row|
      next unless (reason = row.expiry_reason)
      row.end!(reason)
      AuditEvent.record("session.expired", subject: row.user, actor: nil, data: { session_id: row.id, reason: reason, kind: row.kind })
    end
  end
end
