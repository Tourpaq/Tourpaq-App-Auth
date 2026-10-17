# Who the person behind an Entra sign-in is (SPECS.md §3.2). Takes the OmniAuth auth hash (from
# the real strategy, OmniAuth's test mode or the fake identity provider: all the same shape, the
# ID token's claims in extra.raw_info) and returns a Result with the user, or a refusal.
#
# 1. tid must equal ENTRA_TENANT_ID (the strategy checks it too) and oid must be present.
# 2. Find the user by (oid, tid).
# 3. Else bind a pre-created user that is not yet bound, matched once by email (case-insensitive).
# 4. Else create a pending user (no access).
# 5. A disabled user is refused.
# 6. Refresh name, email and UPN from the token; record last_login_at.
#
# Audits user.created / user.bound / auth.login_refused here; the controller records auth.login
# once the session exists.
class EntraSignIn
  Result = Data.define(:user, :error, :message) do
    def success? = error.nil?
  end

  MESSAGES = {
    wrong_tenant: "This Microsoft account is not in the Tourpaq directory.",
    missing_identity: "Microsoft did not say who you are. Try again.",
    missing_email: "Your Microsoft account has no email address. Ask IT to add one.",
    email_in_use: "Another account already uses your email address. Ask an admin to sort it out.",
    disabled: "Your account is disabled. Ask an admin if you think this is a mistake."
  }.freeze

  def self.call(auth) = new(auth).call

  def initialize(auth)
    raw = auth.respond_to?(:extra) && auth.extra ? auth.extra.raw_info : nil
    @claims = (raw || {}).to_h.transform_keys(&:to_s)
  end

  def call
    oid, tid = @claims["oid"].to_s.presence, @claims["tid"].to_s.presence
    expected_tid = Rails.configuration.x.auth.entra_tenant_id
    return refuse(:wrong_tenant, tid: tid) if expected_tid.blank? || !tid.to_s.casecmp?(expected_tid)
    return refuse(:missing_identity) unless oid

    email = (@claims["email"].presence || @claims["preferred_username"].presence).to_s.strip.downcase
    user = User.find_by(entra_oid: oid, entra_tid: tid)
    if user.nil?
      return refuse(:missing_email, oid: oid) unless email.match?(URI::MailTo::EMAIL_REGEXP)
      user = User.unbound.find_by(email: email)
      if user
        return refuse(:disabled, user: user) if user.disabled?
        user.update!(entra_oid: oid, entra_tid: tid)
        AuditEvent.record("user.bound", subject: user, actor: user, data: { email: email })
      elsif User.exists?(email: email)
        return refuse(:email_in_use, email: email, oid: oid)
      else
        user = User.create!(email: email, name: @claims["name"], upn: @claims["preferred_username"], entra_oid: oid, entra_tid: tid)
        AuditEvent.record("user.created", subject: user, actor: user, data: { via: "entra", email: email })
      end
    end
    return refuse(:disabled, user: user) if user.disabled?

    refresh(user, email)
    Result.new(user: user, error: nil, message: nil)
  end

  private

  def refresh(user, email)
    attributes = { name: @claims["name"].presence || user.name, upn: @claims["preferred_username"].presence || user.upn, last_login_at: Time.current }
    # The email follows Entra unless another user already has it (then the old one stays).
    attributes[:email] = email if email.match?(URI::MailTo::EMAIL_REGEXP) && !User.where.not(id: user.id).exists?(email: email)
    user.update!(attributes)
  end

  def refuse(error, user: nil, **data)
    AuditEvent.record("auth.login_refused", subject: user, actor: user,
                      data: { reason: error.to_s, email: @claims["email"].presence || @claims["preferred_username"] }.merge(data).compact)
    Result.new(user: user, error: error, message: MESSAGES.fetch(error))
  end
end
