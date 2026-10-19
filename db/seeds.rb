# The starting point (SPECS.md §1, §5.1, §5.2, §23, §24): the DK Tech admins, three staff groups, the apps we know
# with their roles, DK Tech as admin in every app that has an "admin" role, the apps' clients, and the internal
# clients of the index and admin hosts. Home, formerly the Dashboard (at home.app, §24.1), is registered with
# multiple roles and no roles yet (its standard roles or its import create them, §23.2, §23.5).
#
# Idempotent: existing rows are found and never changed, so anything edited in the admin UI survives
# a re-run (the web container seeds on every start). No secrets are created or printed here: client
# secrets are generated in the admin UI and shown once.
Current.channel = "system"

groups = {
  "DK Tech" => "Tourpaq tech team in Denmark.",
  "RO DevOps" => "DevOps in Romania.",
  "RO Dev" => "Developers in Romania."
}.to_h do |name, description|
  # Tourpaq's own people: they see the index's content for all staff (§24.3).
  [ name, Group.find_or_create_by!(name: name) { _1.description = description; _1.staff = true } ]
end

# Pre-created and unbound: matched by email at their first Entra sign-in (§3.2).
[
  [ "Mogens", "mwi@tourpaq.com" ],
  [ "Jacob", "jjr@tourpaq.com" ],
  [ "Morten", "mso@tourpaq.com" ],
  [ "Sam", "sar@tourpaq.com" ]
].each do |name, email|
  user = User.find_by_email(email) || User.create!(email: email, name: name, admin: true).tap do |created|
    AuditEvent.record("user.precreated", subject: created, actor: nil, data: { email: email, seeded: true })
  end
  GroupMembership.find_or_create_by!(group: groups["DK Tech"], user: user)
end

# url is where the launcher tile goes; dev_port is the app's local port (its redirect URIs).
apps = [
  { slug: "irm", name: "IRM", description: "Incident response: alerts, on-call, incidents and the status page.",
    icon: "bell", url: "https://irm.app.journeybooking.eu", dev_port: 3030,
    roles: [ [ "viewer", "Sees alerts, incidents and schedules" ], [ "responder", "Acknowledges and resolves alerts, takes shifts" ],
             [ "editor", "Configures integrations, escalations and schedules" ], [ "admin", "Manages users and settings" ] ],
    extension: true, extension_ids: [ "fejfbgidhcpfhogplgbomjcacgljdjch" ] }, # fixed by the IRM manifest's "key" (§10)
  { slug: "kpi", name: "KPI", description: "Business key figures and reports.",
    icon: "chart", url: "https://kpi.app.journeybooking.eu", dev_port: 3040,
    roles: [ [ "viewer", "Sees the reports" ], [ "editor", "Edits reports and targets" ], [ "admin", "Manages the app" ] ] },
  { slug: "logs", name: "Logs Analyzer", description: "Search and analyse application logs.",
    icon: "logs", url: "https://logs.app.journeybooking.eu", dev_port: 3020,
    roles: [ [ "viewer", "Reads every page, the MCP read tools and the API" ],
             [ "admin", "Changes settings, ingestion, findings and analyses" ] ] },
  # The host is azurecost.app (no dash), where the app already runs and the index links to; the slug (and so the
  # client azure-cost-web, the claim azure_cost_role and the tpa_azure-cost_ tokens) keeps its dash.
  { slug: "azure-cost", name: "Azure Cost", description: "Azure spending per subscription and service.",
    icon: "cost", url: "https://azurecost.app.journeybooking.eu", dev_port: 3010,
    roles: [ [ "viewer", "Reads costs, inventory and the API" ],
             [ "admin", "Syncs from Azure, edits settings, budgets and migrations" ] ] },
  # The index is part of this app (SPECS.md §24.3): its host signs in as the internal client "index", so it has no
  # web client. The app stays for its browser extension (index-extension, tpx_index_ tokens), whose id is fixed by the
  # manifest "key" in clients/index-extension.
  { slug: "index", name: "Index", description: "The journeybooking index of apps and links.",
    icon: "home", url: "https://index.app.journeybooking.eu", web: false,
    roles: [ [ "viewer", "Uses the app" ], [ "admin", "Manages the app" ] ],
    extension: true, extension_ids: [ "cicimfifinjjjnagflnckioghehdpogc" ] }, # clients/index-extension/manifest.json "key"
  # Home, formerly the Dashboard (SPECS.md §23, §24.1): permission-carrying roles, several per user, at home.app. No
  # roles here: the app page's standard roles (StarterRoles) or the import (auth:import_dashboard) create them, and the
  # app pushes its permission catalogue. Its client is home-web. A database that still has the app as "dashboard" is
  # renamed by the migration RenameDashboardAppToHome before these seeds run, so it is found here and not created twice.
  { slug: "home", name: "Home", description: "Customers, management figures, tasks and the team's daily tools.",
    icon: "home", url: "https://home.app.journeybooking.eu", dev_port: 4013,
    multiple_roles: true, role_claim: "home_roles", admin_permission: "admin:access:manage", token_scopes: %w[public all],
    roles: [], post_logout: [ "https://home.app.journeybooking.eu/" ] }
]

apps.each do |spec|
  app = App.find_by(slug: spec[:slug]) || App.new(spec.slice(:slug, :name, :description, :icon, :url, :multiple_roles, :role_claim,
                                                             :admin_permission, :token_scopes)).tap do |new_app|
    spec[:roles].each_with_index { |(key, description), i| new_app.roles.build(key: key, description: description, position: i + 1) }
    new_app.save!
    AuditEvent.record("app.created", subject: new_app, actor: nil, data: { seeded: true })
  end

  # DK Tech is admin in every app (§5.2).
  if (admin_role = app.role("admin")) && !Grant.exists?(app: app, subject: groups["DK Tech"])
    Grant.create!(app: app, subject: groups["DK Tech"], app_role: admin_role)
  end

  # The web client (confidential; its secret is generated in the admin UI) and, for apps with a
  # browser extension, the public extension client. Its redirect URI is https://<extension-id>.chromiumapp.org/
  # for each extension id fixed by a manifest "key" (§10); without one it has none until an admin adds it.
  base = URI(spec[:url]).then { "#{_1.scheme}://#{_1.host}" }
  local = "http://localhost:#{spec[:dev_port]}"
  spec[:web] == false || Client.find_or_create_by!(client_id: "#{spec[:slug]}-web") do |client|
    client.app = app
    client.kind = "web"
    client.name = "#{spec[:name]} web"
    client.redirect_uris = [ "#{base}/sso/callback", "#{local}/sso/callback" ]
    client.post_logout_redirect_uris = spec[:post_logout] || [ "#{base}/", "#{local}/" ]
  end
  next unless spec[:extension]
  Client.find_or_create_by!(client_id: "#{spec[:slug]}-extension") do |client|
    client.app = app
    client.kind = "extension"
    client.name = "#{spec[:name]} browser extension"
    client.redirect_uris = Array(spec[:extension_ids]).map { "https://#{_1}.chromiumapp.org/" }
  end
end

# The index and admin hosts' own clients (§11.2, §24.1): internal, no secret, redirect URIs from INDEX_URL / ADMIN_URL.
Client.index_client
Client.admin_client

# The index content (§24.3): Tourpaq-App-WWW's seed content (db/seeds/index), loaded only into an empty index, so
# what admins edit on the admin host is never overwritten. Production gets WWW's live content with auth:import_index.
Index::SeedContent.load_if_empty(Rails.root.join("db/seeds/index"), log: Rails.env.test? ? StringIO.new : $stdout)
