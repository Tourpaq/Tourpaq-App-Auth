require "test_helper"
require "action_controller"
require "rack/mock"

# A permission app (the auth app's SPECS.md §23.2, §23.3), like the Dashboard: role lists and permissions on every
# result, the catalogue push, the app's own token scopes. Single-role apps are unchanged (the other tests).
class PermissionAppsTest < TourpaqAuthTestCase
  Entry = Struct.new(:key, :label, :group)

  def dashboard(**options, &block)
    with_auth(client_id: "dashboard-web", multiple_roles: true, token_scopes: %w[public all], **options, &block)
  end

  def add_support(provider)
    provider.add_user(email: "x@tourpaq.com", roles: [ "Finance readers", "Support" ],
                      permissions: %w[management:finance:view module:customers:view])
  end

  def test_the_claims_are_derived_from_the_client_id
    config = TourpaqAuth::Configuration.new("LOGIN_CLIENT_ID" => "dashboard-web")
    assert_equal [ "dashboard_role", "dashboard_roles", "dashboard_permissions" ], [ config.role_claim, config.roles_claim, config.permissions_claim ]
    config = TourpaqAuth::Configuration.new("LOGIN_CLIENT_ID" => "dashboard-web", "LOGIN_PERMISSIONS_CLAIM" => "perms")
    assert_equal "perms", config.permissions_claim
  end

  def test_login_has_roles_and_permissions_and_no_single_role
    dashboard do |provider|
      sub = add_support(provider)
      url, login = TourpaqAuth::Client.begin_login
      result = TourpaqAuth::Client.complete_login(login, provider.authorize(url, sub: sub))
      assert_nil result.role
      assert_equal [ "Finance readers", "Support" ], result.roles
      assert_equal %w[management:finance:view module:customers:view], result.permissions
      assert result.permission?("module:customers:view")
      refute result.permission?("admin:access:manage")
      assert result.role?("Support")
    end
  end

  def test_login_finds_the_role_list_without_login_role_claim
    with_auth(client_id: "dashboard-web", multiple_roles: true, env: { "LOGIN_ROLE_CLAIM" => nil }) do |provider|
      TourpaqAuth.config.role_claim = nil
      sub = provider.add_user(email: "x@tourpaq.com", roles: [ "Administrators" ], permissions: [ "*" ])
      url, login = TourpaqAuth::Client.begin_login
      result = TourpaqAuth::Client.complete_login(login, provider.authorize(url, sub: sub))
      assert_equal [ "Administrators" ], result.roles
      assert result.permission?("anything:at:all"), "* means everything"
    end
  end

  def test_single_role_logins_get_roles_from_the_role
    with_auth(client_id: "irm-web") do |provider|
      sub = provider.add_user(email: "x@tourpaq.com", role: "responder")
      url, login = TourpaqAuth::Client.begin_login
      result = TourpaqAuth::Client.complete_login(login, provider.authorize(url, sub: sub))
      assert_equal [ "responder", [ "responder" ], [] ], [ result.role, result.roles, result.permissions ]
    end
    login = TourpaqAuth::Login.new(sub: "s", email: nil, name: nil, role: "viewer", sessions_valid_after: nil, authenticated_at: nil, claims: {})
    assert_equal [ [ "viewer" ], [] ], [ login.roles, login.permissions ]
  end

  def test_access_check_and_members_carry_roles_and_permissions
    dashboard do |provider|
      sub = add_support(provider)
      result = TourpaqAuth::Access.check(sub)
      assert result.active?
      assert_nil result.role
      assert_equal [ [ "Finance readers", "Support" ], %w[management:finance:view module:customers:view] ], [ result.roles, result.permissions ]
      cached = TourpaqAuth::Access.check(sub)
      assert_equal result.permissions, cached.permissions, "from the cache too"

      members = TourpaqAuth::Access.members
      assert_equal [ [ "Finance readers", "Support" ] ], members.members.map(&:roles)
      assert members.members.first.permission?("management:finance:view")

      provider.set_roles(sub, [ "Support" ], permissions: %w[module:customers:view])
      changed = TourpaqAuth::Access.members(etag: members.etag)
      refute changed.not_modified?, "the ETag changes with the permissions"
      assert_equal [ %w[module:customers:view] ], changed.members.map(&:permissions)

      provider.remove_access(sub)
      gone = TourpaqAuth::Access.check(sub, force: true)
      refute gone.active?
      assert_equal [ [], [] ], [ gone.roles, gone.permissions ]
    end
  end

  def test_introspection_carries_roles_permissions_and_the_apps_scope
    dashboard do |provider|
      sub = add_support(provider)
      token = provider.issue_token(sub: sub, scope: "all")
      result = TourpaqAuth::Tokens.introspect(token)
      assert result.active?
      assert result.scope?("all")
      refute result.scope?("public")
      refute result.read_write?
      assert_equal [ [ "Finance readers", "Support" ], true ], [ result.roles, result.permission?("module:customers:view") ]
      assert_equal "public", TourpaqAuth::Tokens.introspect(provider.issue_token(sub: sub)).scope, "the lowest by default"
      assert_equal "all", TourpaqAuth::Tokens.introspect(provider.issue_token(sub: sub, token_type: "extension")).scope
      assert_raises(ArgumentError) { provider.issue_token(sub: sub, scope: "read_write") }
      refute TourpaqAuth::Tokens::INACTIVE.permission?("x")
    end
  end

  def test_catalogue_push
    dashboard do |provider|
      result = TourpaqAuth::Catalogue.push([ { key: "module:customers:view", label: "Customers", group: "Modules" },
                                             { "key" => "admin:access:manage", "group_label" => "Administration" },
                                             Entry.new("module:tasks:view", "Tasks", "Modules") ])
      assert_equal [ "dashboard", 3, %w[admin:access:manage module:customers:view module:tasks:view], [] ],
                   [ result.app, result.count, result.added, result.removed ]
      assert_equal({ "key" => "admin:access:manage", "label" => nil, "group" => "Administration" }, provider.catalogue[1])
      request = provider.requests.last
      assert_equal [ :put, "/api/v1/catalogue", "application/json" ], [ request[:method], request[:path], request[:headers]["Content-Type"] ]
      assert_equal "Basic #{['dashboard-web:test-client-secret'].pack('m0')}", request[:headers]["Authorization"]

      result = TourpaqAuth::Catalogue.push([ { key: "module:customers:view" } ])
      assert_equal %w[admin:access:manage module:tasks:view], result.removed
      assert_equal 2, provider.catalogue_pushes

      provider.catalogue_status = 400
      error = assert_raises(TourpaqAuth::Refused) { TourpaqAuth::Catalogue.push([]) }
      assert_equal 400, error.status
      provider.catalogue_status = nil
      provider.reachable = false
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Catalogue.push([]) }
    end
  end
end

class PermissionPagesController < ActionController::Base
  include TourpaqAuth::Rails::AccessCheck

  class << self
    attr_accessor :applied
  end

  skip_tourpaq_auth_access_check only: :login

  def show = render(plain: "ok")

  def login
    tourpaq_auth_signed_in(TourpaqAuth::Login.new(sub: params[:sub], email: nil, name: nil, role: nil, roles: [ "Support" ],
                                                  permissions: %w[module:customers:view], sessions_valid_after: nil,
                                                  authenticated_at: nil, claims: {}))
    render plain: "signed in"
  end

  private

  def tourpaq_auth_end_session(reason, _result) = redirect_to("/login")

  def tourpaq_auth_apply_permissions(roles, permissions, _result)
    self.class.applied << [ roles, permissions ]
  end
end

class ScopedApiController < ActionController::API
  include TourpaqAuth::Rails::BearerToken

  require_tourpaq_auth_token
  require_tourpaq_auth_token scope: "all", only: :internal

  def index = render(json: { ok: true })
  def internal = render(json: { ok: true })
end

class PermissionConcernsTest < TourpaqAuthTestCase
  def setup
    super
    @session = {}
    PermissionPagesController.applied = []
  end

  def request(action, params = {})
    env = Rack::MockRequest.env_for("/#{action}?#{URI.encode_www_form(params)}", "rack.session" => @session)
    PermissionPagesController.action(action).call(env).first
  end

  def test_changed_permissions_are_applied_once
    with_auth(client_id: "dashboard-web", multiple_roles: true) do |provider|
      sub = provider.add_user(email: "x@tourpaq.com", roles: [ "Support" ], permissions: %w[module:customers:view])
      request(:login, sub: sub)
      travel 301
      assert_equal 200, request(:show)
      assert_empty PermissionPagesController.applied, "the same as at login"

      provider.set_roles(sub, [ "Support", "Finance readers" ], permissions: %w[management:finance:view module:customers:view])
      travel 301
      assert_equal 200, request(:show)
      assert_equal [ [ [ "Support", "Finance readers" ], %w[management:finance:view module:customers:view] ] ], PermissionPagesController.applied
      travel 301
      request(:show)
      assert_equal 1, PermissionPagesController.applied.size
    end
  end

  def call_api(action, token)
    env = Rack::MockRequest.env_for("/#{action}")
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}"
    status, headers, = ScopedApiController.action(action).call(env)
    [ status, headers.transform_keys(&:downcase) ]
  end

  def test_require_a_scope_of_the_apps_own_list
    with_auth(client_id: "dashboard-web", multiple_roles: true, token_scopes: %w[public all]) do |provider|
      sub = provider.add_user(email: "x@tourpaq.com", roles: [ "Support" ])
      public_token = provider.issue_token(sub: sub, scope: "public")
      assert_equal 200, call_api(:index, public_token).first
      status, headers = call_api(:internal, public_token)
      assert_equal 403, status
      assert_equal %(Bearer error="insufficient_scope", scope="all"), headers["www-authenticate"]
      assert_equal 200, call_api(:internal, provider.issue_token(sub: sub, scope: "all")).first
    end
  end
end
