# The admin host's start page: pending users, counts, and what needs attention soon (client secrets
# expiring within 30 days; roles holding permissions their app's catalogue does not know, SPECS.md §23.2;
# the Entra secret banner is in the layout).
class Admin::DashboardController < Admin::BaseController
  def show
    @pending = User.pending.order(created_at: :desc).limit(20).to_a
    @pending_count = User.pending.count
    @user_count = User.active.count
    @app_count = App.active.count
    @group_count = Group.count
    @token_count = PersonalToken.active.count
    @expiring_secrets = ClientSecret.active.where.not(expires_at: nil).where(expires_at: ..ClientSecret::WARN_BEFORE.from_now)
                                    .includes(client: :app).order(:expires_at).to_a
    @unknown_permissions = App.where(multiple_roles: true).ordered.includes(:roles, :catalogue).flat_map do |app|
      app.unknown_permissions.map { |role, keys| [ app, role, keys ] }
    end
  end
end
