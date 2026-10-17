# Hourly (config/recurring.yml): records token.expired (SPECS.md §12) once for each personal token
# that has run out without being revoked. The token stays in the list (as expired); apps already
# refuse it (introspection checks expires_at), so this is bookkeeping for the audit log.
class TokenExpiryJob < ApplicationJob
  BATCH = 500

  def perform
    Current.set(channel: "system") do
      recorded = AuditEvent.where(action: "token.expired", subject_type: "PersonalToken").select(:subject_id)
      PersonalToken.where(revoked_at: nil, expires_at: ...Time.current).where.not(id: recorded)
                   .includes(:app).order(:expires_at).limit(BATCH).each do |token|
        AuditEvent.record("token.expired", subject: token, actor: nil,
                          data: { user_id: token.user_id, app: token.app.slug, name: token.name, hint: token.token_hint,
                                  expired_at: token.expires_at.utc.iso8601 })
      end
    end
  end
end
