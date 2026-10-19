require "test_helper"

# The seeds (SPECS.md §1, §5, §24): admins, groups, apps, clients; idempotent, no secrets.
class SeedsTest < ActiveSupport::TestCase
  setup do
    [ Index::Link, Index::EntryGroup, Index::Entry, Index::Doc, Index::DocSection, Index::SectionGroup, Index::Section,
      Index::AccessLevel, Index::LoginMethod, Index::Site ].each(&:delete_all)
    [ AuditEvent, Grant, GroupMembership, ClientSecret, Client, AppRole, App, Group, Session, User ].each(&:delete_all)
  end

  def seed = Rails.application.load_seed

  test "creates the DK Tech admins, groups, apps with ordered roles, grants and clients" do
    seed
    admins = User.admins.order(:email)
    assert_equal %w[jjr@tourpaq.com mso@tourpaq.com mwi@tourpaq.com sar@tourpaq.com], admins.map(&:email)
    assert_equal %w[Jacob Morten Mogens Sam], admins.map(&:name)
    assert admins.none?(&:bound?)
    assert_equal [ "DK Tech", "RO Dev", "RO DevOps" ], Group.ordered.pluck(:name)
    assert_equal admins.to_a.sort_by(&:id), Group.find_by!(name: "DK Tech").users.sort_by(&:id)
    assert_empty Group.find_by!(name: "RO Dev").users

    irm = App.find_by!(slug: "irm")
    assert_equal %w[viewer responder editor admin], irm.role_keys
    assert_equal "irm_role", irm.role_claim
    assert_equal "https://irm.app.journeybooking.eu", irm.url
    assert_equal %w[viewer editor admin], App.find_by!(slug: "kpi").role_keys
    assert_equal "azure_cost_role", App.find_by!(slug: "azure-cost").role_claim
    # The host Azure Cost runs at, and the index links to, has no dash (the slug keeps its dash).
    assert_equal "https://azurecost.app.journeybooking.eu", App.find_by!(slug: "azure-cost").url
    assert_equal [ "https://azurecost.app.journeybooking.eu/sso/callback", "http://localhost:3010/sso/callback" ],
                 Client.find_by!(client_id: "azure-cost-web").redirect_uris
    assert_equal "https://index.app.journeybooking.eu", App.find_by!(slug: "index").url
    %w[logs azure-cost index].each { assert_equal %w[viewer admin], App.find_by!(slug: _1).role_keys }

    App.where.not(slug: "home").find_each do |app|
      assert_equal "admin, from DK Tech", EffectiveRole.for(User.find_by_email("mwi@tourpaq.com"), app).to_s, app.slug
    end

    # Home, formerly the Dashboard (§23): multiple roles, no roles yet (its standard roles or the import create them),
    # its scopes and claims, client home-web. It stays at home.app (§24.1).
    dashboard = App.find_by!(slug: "home")
    assert_equal [ "Home", "https://home.app.journeybooking.eu", true, "home_roles", "home_permissions",
                   "admin:access:manage", %w[public all] ],
                 [ dashboard.name, dashboard.url, dashboard.multiple_roles?, dashboard.role_claim, dashboard.permissions_claim,
                   dashboard.admin_permission, dashboard.token_scopes ]
    assert_empty dashboard.roles
    assert_empty dashboard.grants
    dashboard_web = Client.find_by!(client_id: "home-web")
    assert_equal [ dashboard, "web" ], [ dashboard_web.app, dashboard_web.kind ]
    assert_equal [ "https://home.app.journeybooking.eu/sso/callback", "http://localhost:4013/sso/callback" ], dashboard_web.redirect_uris
    assert_equal [ "https://home.app.journeybooking.eu/" ], dashboard_web.post_logout_redirect_uris

    # The index host signs in as the internal client "index" (§24.1): no index-web.
    assert_equal %w[admin azure-cost-web home-web index index-extension irm-extension irm-web kpi-web logs-web], Client.order(:client_id).pluck(:client_id)
    web = Client.find_by!(client_id: "irm-web")
    assert web.redirect_uri_allowed?("https://irm.app.journeybooking.eu/sso/callback")
    assert web.redirect_uri_allowed?("http://localhost:3030/sso/callback")
    irm_extension = Client.find_by!(client_id: "irm-extension")
    assert irm_extension.extension?
    assert_equal [ "https://fejfbgidhcpfhogplgbomjcacgljdjch.chromiumapp.org/" ], irm_extension.redirect_uris,
                 "the IRM extension's id is fixed by its manifest key, so its redirect URI is known"
    assert_equal [ "https://cicimfifinjjjnagflnckioghehdpogc.chromiumapp.org/" ], Client.find_by!(client_id: "index-extension").redirect_uris,
                 "the index extension's id is fixed by its manifest key (clients/index-extension)"
    assert Client.find_by!(client_id: "admin").internal?
    index = Client.find_by!(client_id: "index")
    assert_equal [ true, nil, [ "http://index.example.com/sso/callback" ] ], [ index.internal?, index.app, index.redirect_uris ]
    assert_equal 0, ClientSecret.count, "no secrets in seeds"
  end

  test "the index content (§24.3): WWW's seed content, the Dashboard's card at home.app tied to its app, technical for DK Tech and RO DevOps" do
    seed
    assert_equal "Tourpaq DK Home", Index::Site.current.title
    dashboard = Index::Entry.find_by!(slug: "home")
    assert_equal [ "Tourpaq Home", "https://home.app.journeybooking.eu", App.find_by!(slug: "home") ],
                 [ dashboard.name, dashboard.url, dashboard.app ]
    assert_equal App.find_by!(slug: "azure-cost"), Index::Entry.find_by!(slug: "azure-cost-overview").app
    assert_equal [ "DK Tech", "RO DevOps" ], Index::Section.find_by!(name: "DevOps").groups.map(&:name).sort
    assert_equal %w[Apps Reporting], Index::Section.where(visibility: "everyone").ordered.pluck(:name)

    # The seeded groups are staff. A user of DK Tech sees the technical sections; a user with only Home (a customer,
    # in no staff group) sees none of the content, only Home under "Your apps".
    assert_equal [ true ], Group.distinct.pluck(:staff)
    mwi = User.find_by_email("mwi@tourpaq.com")
    assert Index::Section.visible_to(Index::Viewer.new(mwi)).exists?(name: "Databases")
    someone = User.create!(email: "someone@bravo.example")
    home = App.find_by!(slug: "home")
    Grant.create!(app: home, subject: someone, app_role: home.add_role!("Support", permissions: %w[module:customers:view]))
    viewer = Index::Viewer.new(someone)
    assert_empty Index::Section.visible_to(viewer)
    assert_empty Index::Entry.visible_to(viewer)
    assert_empty Index::Doc.visible_to(viewer)
    assert_equal [ home ], viewer.your_apps([]).map(&:app)
  end

  test "running again changes nothing, and edits survive" do
    seed
    App.find_by!(slug: "irm").update!(name: "Incidents")
    App.find_by!(slug: "home").update!(token_scope_list: "public internal all")
    App.find_by!(slug: "home").add_role!("Support", permissions: %w[module:customers:view])
    User.find_by_email("mwi@tourpaq.com").update!(name: "Mogens Winther")
    Index::Entry.find_by!(slug: "home").update!(name: "Dashboard")
    Index::Entry.find_by!(slug: "salesview").destroy!
    counts = [ User, Group, GroupMembership, App, AppRole, Grant, Client, Index::Entry, Index::Section, Index::Doc ].map(&:count)
    seed
    assert_equal counts, [ User, Group, GroupMembership, App, AppRole, Grant, Client, Index::Entry, Index::Section, Index::Doc ].map(&:count)
    assert_equal "Dashboard", Index::Entry.find_by!(slug: "home").name, "the index is seeded only when empty"
    assert_equal "Incidents", App.find_by!(slug: "irm").name
    assert_equal %w[public internal all], App.find_by!(slug: "home").token_scopes
    assert_equal [ "Support" ], App.find_by!(slug: "home").role_keys
    assert_equal "Mogens Winther", User.find_by_email("mwi@tourpaq.com").name
  end
end
