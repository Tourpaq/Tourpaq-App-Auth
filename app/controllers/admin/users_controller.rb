# Users (SPECS.md §11.2): the list with filters (pending first), the user page and its actions, and
# adding a user by email in advance (pre-created, bound at their first sign-in, §3.2).
# disable!/enable!/make_admin!/remove_admin!/sign_out_everywhere! audit themselves; the last
# active admin is protected by the model (RecordInvalid).
class Admin::UsersController < Admin::BaseController
  FILTERS = %w[pending disabled admins unbound].freeze

  before_action :set_user, except: %i[index new create]

  def index
    @apps = App.ordered.to_a
    @groups = Group.ordered.to_a
    @filter = params[:filter].presence_in(FILTERS)
    scope = User.includes(:groups)
    scope = case @filter
            when "pending" then scope.merge(User.pending)
            when "disabled" then scope.disabled
            when "admins" then scope.admins
            when "unbound" then scope.unbound
            else scope
            end
    if (group = @groups.detect { _1.id.to_s == params[:group_id].to_s })
      @group = group
      scope = scope.where(id: group.group_memberships.select(:user_id))
    end
    if (app = @apps.detect { _1.id.to_s == params[:app_id].to_s })
      @app = app
      @app_roles = EffectiveRole.members_of(app).index_by { _1.user.id }
      scope = scope.where(id: @app_roles.keys)
    end
    if params[:q].present?
      q = "%#{User.sanitize_sql_like(params[:q].to_s.strip.downcase)}%"
      scope = scope.where("LOWER(users.email) LIKE :q OR LOWER(users.name) LIKE :q", q: q)
    end
    @pending_ids = User.pending.pluck(:id).to_set
    # Pending users first (§11.2), then by name.
    @users = scope.ordered.to_a.sort_by.with_index { |user, i| [ @pending_ids.include?(user.id) ? 0 : 1, i ] }
  end

  def show
    @apps = App.ordered.includes(:roles).to_a
    @access = @apps.to_h { [ _1.id, EffectiveRole.for(@user, _1) ] }
    @direct = @user.grants.includes(:app_role).group_by(&:app_id)
    @memberships = @user.group_memberships.includes(:group).sort_by { _1.group.name.downcase }
    @other_groups = Group.ordered.where.not(id: @memberships.map(&:group_id))
    @sessions = @user.sessions.active.recent_first.to_a
    @tokens = @user.personal_tokens.includes(:app).recent_first.to_a
    @extensions = ExtensionSignIns.for(@user)
    @recent_events = AuditEvent.where(subject: @user).or(AuditEvent.where(actor: @user)).recent_first.includes(:actor, :app).limit(15)
  end

  def new
    @user = User.new
  end

  def create
    @user = User.new(params.expect(user: %i[email name]))
    existing = User.find_by_email(@user.email)
    return redirect_to(admin_user_path(existing), alert: "#{existing.email} is already a user.") if existing

    if @user.save
      AuditEvent.record("user.precreated", subject: @user, data: { email: @user.email })
      redirect_to admin_user_path(@user), notice: "#{@user.email} is added. Give access now; it is theirs at their first sign-in."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def disable
    return refused("You cannot disable yourself.", to: admin_user_path(@user)) if @user == current_admin
    @user.disable!(reason: params[:reason].presence)
    redirect_to admin_user_path(@user), notice: "#{@user.display_name} is disabled: sessions ended, extensions signed out, tokens refused."
  rescue ActiveRecord::RecordInvalid
    refused(@user, to: admin_user_path(@user))
  end

  def enable
    @user.enable!
    redirect_to admin_user_path(@user), notice: "#{@user.display_name} is enabled."
  end

  def make_admin
    @user.make_admin!
    redirect_to admin_user_path(@user), notice: "#{@user.display_name} is now an admin."
  rescue ActiveRecord::RecordInvalid
    refused(@user, to: admin_user_path(@user))
  end

  def remove_admin
    return refused("You cannot remove your own admin rights. Ask another admin.", to: admin_user_path(@user)) if @user == current_admin
    @user.remove_admin!
    redirect_to admin_user_path(@user), notice: "#{@user.display_name} is no longer an admin."
  rescue ActiveRecord::RecordInvalid
    refused(@user, to: admin_user_path(@user))
  end

  def sign_out_everywhere
    @user.sign_out_everywhere!
    if @user == current_admin
      end_admin_session("signed_out_everywhere")
      redirect_to admin_root_path
    else
      redirect_to admin_user_path(@user), notice: "#{@user.display_name} is signed out everywhere. The apps end their sessions within 5 minutes."
    end
  end

  private

  def set_user
    @user = User.find(params[:id])
  end
end
