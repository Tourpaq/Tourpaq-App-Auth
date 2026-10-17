# The authorization API (SPECS.md §8): how the apps re-check access during a session.
#
#   GET /api/v1/access/:sub   one user's access to the calling app (§8.1), Cache-Control max-age=300
#   GET /api/v1/access        everybody with access to the calling app (§8.2), with ETag / If-None-Match
#
# Times are Unix seconds (sessions_valid_after, rounded up: User#sessions_valid_after_epoch) and ISO 8601 UTC
# (checked_at). When active is false (unknown user, disabled, or no access) role, email, name and sessions_valid_after
# are null: an app learns nothing about people who are not its users.
#
# A multiple-roles app (SPECS.md §23.2) also gets "roles" (role names) and "permissions" (their sorted union,
# "*" as is), empty lists when active is false; "role" is always null there. The members list's ETag is a
# hash of the body, so it changes when anybody's roles or permissions do.
class Api::V1::AccessController < Api::BaseController
  MAX_AGE = 5.minutes

  def show
    user = User.find_by(sub: params[:sub].to_s)
    result = EffectiveRole.for(user, current_app)
    active = user.present? && result.access?
    expires_in MAX_AGE, public: false
    body = {
      sub: params[:sub].to_s, active: active, role: active ? result.role_key : nil,
      email: active ? user.email : nil, name: active ? user.name : nil,
      sessions_valid_after: active ? user.sessions_valid_after_epoch : nil,
      checked_at: Time.current.utc.iso8601
    }
    body.merge!(roles: active ? result.role_keys : [], permissions: active ? result.permissions : []) if current_app.multiple_roles?
    render json: body
  end

  def index
    members = EffectiveRole.members_of(current_app).map do |result|
      user = result.user
      member = { sub: user.sub, role: result.role_key, email: user.email, name: user.name, sessions_valid_after: user.sessions_valid_after_epoch }
      member.merge!(roles: result.role_keys, permissions: result.permissions) if current_app.multiple_roles?
      member
    end
    body = { app: current_app.slug, members: members }.to_json
    etag = %(W/"#{Digest::SHA256.hexdigest(body).first(32)}")
    response.set_header("ETag", etag)
    response.set_header("Cache-Control", "private, no-cache")
    return head(:not_modified) if if_none_match.include?(etag) || if_none_match.include?("*")
    render json: body
  end

  private

  def if_none_match = request.headers["If-None-Match"].to_s.split(",").map(&:strip)
end
