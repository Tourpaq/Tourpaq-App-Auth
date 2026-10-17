# The Tokens page (SPECS.md §9.1), on the index host: the signed-in user's personal API/MCP tokens. Create one for an app
# they have access to (name, a scope from that app's own list — read / read_write by default, the Dashboard's
# public / all, §23.3 — lifetime 30 / 90 / 365 days), see it once, list
# them (app, name, scope, created, expires, last used) and revoke them. At most
# PersonalToken::MAX_ACTIVE active tokens. PersonalToken.issue! and #revoke! write the audit events.
class Index::TokensController < Index::BaseController
  rate_limit to: 10, within: 10.minutes, only: :create, store: RateLimitStore.store, by: -> { "tokens:#{current_user.id}" },
             with: -> { redirect_to index_tokens_path, alert: "You created many tokens in a short time. Wait a few minutes." }

  def index
    @token = PersonalToken.new(lifetime_days: PersonalToken::DEFAULT_LIFETIME, app: accessible_apps.first,
                               scope: accessible_apps.first&.lowest_token_scope)
    load_page
  end

  def create
    attrs = params.expect(personal_token: %i[app_id name scope lifetime_days])
    app = accessible_apps.detect { _1.id == attrs[:app_id].to_i }
    unless app
      @token = PersonalToken.new(name: attrs[:name], scope: attrs[:scope], app: accessible_apps.first)
      @token.errors.add(:app, "must be one you have access to")
      load_page
      return render(:index, status: :unprocessable_content)
    end
    plain = PersonalToken.issue!(user: current_user, app: app, name: attrs[:name].to_s, scope: attrs[:scope].to_s,
                                 lifetime_days: attrs[:lifetime_days].presence || PersonalToken::DEFAULT_LIFETIME, actor: current_user)
    @plain = plain
    @token = PersonalToken.find_by_plain(plain)
    response.set_header("Cache-Control", "no-store")
    render :created
  rescue ActiveRecord::RecordInvalid => e
    @token = e.record
    load_page
    render :index, status: :unprocessable_content
  end

  def destroy
    token = current_user.personal_tokens.find(params[:id])
    if token.revoke!(actor: current_user)
      redirect_to index_tokens_path, notice: "Token “#{token.name}” is revoked. Apps refuse it within a minute."
    else
      redirect_to index_tokens_path, notice: "Token “#{token.name}” was already revoked."
    end
  end

  private

  def accessible_apps = @accessible_apps ||= EffectiveRole.apps_for(current_user).map(&:app)

  # The scope list follows the chosen app (the token-scopes Stimulus controller swaps it; the server checks it).
  def load_page
    @apps = accessible_apps
    @scope_app = @token&.app || @apps.first || App.new
    @scopes_by_app = @apps.to_h { |app| [ app.id, app.token_scopes.map { [ helpers.token_scope_label(_1).upcase_first, _1 ] } ] }
    @tokens = current_user.personal_tokens.includes(:app).recent_first
    @active_count = current_user.personal_tokens.active.count
  end
end
