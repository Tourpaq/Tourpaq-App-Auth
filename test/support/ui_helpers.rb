# Builders for the UI tests (index, profile, admin pages).
module UiHelpers
  # A signed-in browser extension: one refresh token chain (an access token and the current refresh
  # token) for the client, as the OIDC provider would issue it. Returns the refresh token.
  def create_extension_sign_in(user, client = clients(:irm_extension), created_at: Time.current)
    chain = SecureRandom.uuid
    access = OauthToken.new(client: client, user: user, kind: "access", chain_id: chain, expires_at: 1.hour.from_now, created_at: created_at)
    access.assign_new_token(prefix: OauthToken.prefix_for(:access, client.app))
    access.save!
    refresh = OauthToken.new(client: client, user: user, kind: "refresh", chain_id: chain, expires_at: 30.days.from_now, created_at: created_at)
    refresh.assign_new_token(prefix: OauthToken.prefix_for(:refresh, client.app))
    refresh.save!
    refresh
  end

  # A personal token for the user (they must have access to the app). Returns the record.
  def create_personal_token(user, app, name: "Claude Code", **options)
    PersonalToken.find_by_plain(PersonalToken.issue!(user: user, app: app, name: name, actor: user, **options))
  end

  def audit(action) = AuditEvent.where(action: action).order(:id).last
end

ActiveSupport::TestCase.include(UiHelpers)
