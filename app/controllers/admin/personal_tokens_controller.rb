# Every user's personal API/MCP tokens (SPECS.md §9.1): admins see them all, tokens unused for 90
# days flagged, and revoke any (PersonalToken#revoke! audits token.revoked).
class Admin::PersonalTokensController < Admin::BaseController
  STATES = %w[active unused expiring revoked expired all].freeze

  def index
    @state = params[:state].presence_in(STATES) || "active"
    @apps = App.ordered.to_a
    scope = PersonalToken.includes(:user, :app, :revoked_by)
    scope = case @state
            when "active" then scope.active
            when "unused" then scope.unused
            when "expiring" then scope.expiring_soon
            when "revoked" then scope.revoked
            when "expired" then scope.where(revoked_at: nil).where(expires_at: ...Time.current)
            else scope
            end
    scope = scope.where(app_id: params[:app_id]) if params[:app_id].present?
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    @tokens = scope.order(created_at: :desc).limit(500).to_a
    @unused_ids = PersonalToken.unused.where(id: @tokens.map(&:id)).pluck(:id).to_set
  end

  def destroy
    token = PersonalToken.includes(:user, :app).find(params[:id])
    token.revoke!(actor: current_admin)
    redirect_back_or_to admin_tokens_path, notice: "Token #{token.name} of #{token.user.display_name} is revoked."
  end
end
