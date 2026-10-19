# A permission app like the Dashboard (SPECS.md §23.2) for tests, built on demand so the shared fixtures stay as
# they are:
#
#   app = create_dashboard_app                      # multiple roles, admin permission, scopes public < all,
#                                                   # client home-web, the catalogue below pushed
#   app.role("Support")                             # roles: Administrators (*), Support, Finance readers
#   grant_dashboard(users(:alice), "Support")       # a direct grant (GrantChange, audited)
module DashboardHelpers
  DASHBOARD_CATALOGUE = [
    { "key" => "module:customers:view", "label" => "Customers", "group" => "Modules" },
    { "key" => "module:tasks:view", "label" => "Tasks", "group" => "Modules" },
    { "key" => "management:finance:view", "label" => "Finance figures", "group" => "Confidential" },
    { "key" => "admin:access:manage", "label" => "Access management", "group" => "Administration" },
    { "key" => "admin:diagnostics:view", "label" => "Diagnostics", "group" => "Administration" }
  ].freeze

  def create_dashboard_app(catalogue: true, roles: true)
    app = App.create!(slug: "home", name: "Dashboard", url: "https://home.app.journeybooking.eu", icon: "home",
                      multiple_roles: true, role_claim: "home_roles", admin_permission: "admin:access:manage",
                      token_scope_list: "public all")
    if roles
      app.add_role!("Administrators", description: "Everything", permissions: [ "*" ])
      app.add_role!("Support", description: "Customers and tasks", permissions: %w[module:customers:view module:tasks:view])
      app.add_role!("Finance readers", permissions: %w[management:finance:view module:customers:view])
    end
    Client.create!(app: app, client_id: "home-web", kind: "web", name: "Dashboard web",
                   redirect_uris: [ "https://home.app.journeybooking.eu/sso/callback", "http://localhost:4013/sso/callback" ],
                   post_logout_redirect_uris: [ "https://home.app.journeybooking.eu/" ])
    CataloguePush.call(app, DASHBOARD_CATALOGUE.map(&:dup)) if catalogue
    app.reload
  end

  def grant_dashboard(subject, role_name, app: App.find_by!(slug: "home"))
    grant = GrantChange.set(app: app, subject: subject, role: role_name && app.role(role_name))
    assert grant.errors.empty?, grant.errors.full_messages.to_sentence
    grant
  end
end

ActiveSupport::TestCase.include(DashboardHelpers)
ActionDispatch::IntegrationTest.include(DashboardHelpers)
