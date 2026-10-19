require "test_helper"

# The index content screens on the admin host (SPECS.md §24.3; WWW's /admin): CRUD for everything, audited, and the
# overview's gaps. Admins only, and only on the admin host.
class Admin::IndexContentTest < ActionDispatch::IntegrationTest
  setup { sign_in_admin users(:mwi) }

  def audit(action) = AuditEvent.where(action: action).order(:id).last

  test "every screen renders" do
    [ "/index", "/index/entries", "/index/entries/new", "/index/entries/salesview/edit",
      "/index/sections", "/index/sections/new", "/index/sections/databases/edit",
      "/index/access_levels", "/index/access_levels/new", "/index/access_levels/#{index_access_levels(:netbird).id}/edit",
      "/index/login_methods", "/index/login_methods/#{index_login_methods(:sso).id}/edit",
      "/index/docs", "/index/docs/new", "/index/docs/#{index_docs(:deploying).id}/edit",
      "/index/doc_sections", "/index/doc_sections/#{index_doc_sections(:deployment).id}/edit", "/index/site/edit" ].each do |path|
      get path
      assert_response :success, path
    end
    assert_select ".sidebar a.nav-item[href='/index']", "Index content"
  end

  test "only admins, only on the admin host" do
    reset!
    on_admin_host!
    get "/index/entries"
    assert_admin_sign_in_started
    sign_in_index users(:mwi)
    get "/index/entries"
    assert_response :not_found
  end

  test "the overview lists the gaps: missing pills or section, seen by nobody, apps without an entry" do
    index_sections(:databases).section_groups.delete_all
    get "/index"
    assert_response :success
    assert_select "td a", "MS SQL Master - Bravo"
    assert_select "li", /Section\s+Databases/
    assert_select "li a", "KPI"
    assert_select "li a[href=?]", "/index/entries/new?app_id=#{apps(:kpi).id}", "Add its entry"
    get "/index/entries/new?app_id=#{apps(:kpi).id}"
    assert_select "input[name='index_entry[name]'][value=KPI]"
  end

  test "the overview: a doc section seen by nobody, and a warning while no group is staff" do
    get "/index"
    assert_select ".flash-alert", { text: /No group is marked/, count: 0 }
    index_doc_sections(:deployment).update!(visibility: "groups")
    Group.update_all(staff: false)
    get "/index"
    assert_select "li", /Doc section\s+Deployment/
    assert_select ".flash-alert", /No group is marked Tourpaq staff/
  end

  test "add an entry with links, audited" do
    assert_difference -> { Index::Entry.count } => 1, -> { Index::Link.count } => 2 do
      post "/index/entries", params: { index_entry: {
        name: "Booking Monitor", description: "Watches the queue.", section_id: index_sections(:apps).id,
        url: "https://bm.tourpaq.com", status: "beta", access_level_id: index_access_levels(:netbird).id,
        visibility: "groups", group_ids: [ "", groups(:ro_dev).id.to_s ],
        links_attributes: {
          "1" => { label: "Queue", url: "https://bm.tourpaq.com/queue", position: 0 },
          "2" => { label: "Alerts", url: "https://bm.tourpaq.com/alerts", note: "last 24h", position: 1 },
          "3" => { label: "", url: "", note: "" }
        }
      } }
    end
    entry = Index::Entry.find_by!(slug: "booking-monitor")
    assert_redirected_to "/index/entries/booking-monitor/edit"
    assert_equal %w[Queue Alerts], entry.links.map(&:label)
    assert_equal [ "RO Dev" ], entry.groups.map(&:name)
    event = audit("index.entry.created")
    assert_equal [ entry, users(:mwi), "admin" ], [ event.subject, event.actor, event.channel ]
    assert_equal [ "RO Dev" ], event.data["groups"]

    reset!
    sign_in_index users(:alice)
    assert_select ".ix-card .ix-card-name", text: "Booking Monitor"
    reset!
    sign_in_index users(:mwi)
    assert_select ".ix-card .ix-card-name", text: "Booking Monitor", count: 0
  end

  test "an invalid entry is shown again with the reason; script urls are refused" do
    post "/index/entries", params: { index_entry: { name: "", description: "" } }
    assert_response :unprocessable_content
    assert_select ".errors", /Name can't be blank/
    post "/index/entries", params: { index_entry: { name: "X", description: "Y", url: "javascript:alert(1)" } }
    assert_response :unprocessable_content
    assert_select ".errors", /must start with https/
  end

  test "edit, rename, tie to an app and remove a link, audited with what changed" do
    entry = index_entries(:salesview)
    link = index_links(:salesview_admin)
    patch "/index/entries/salesview", params: { index_entry: {
      name: "Salesview 2", slug: "salesview-2", app_id: apps(:kpi).id,
      links_attributes: { "0" => { id: link.id, label: link.label, url: link.url, _destroy: "1" } }
    } }
    assert_redirected_to "/index/entries/salesview-2/edit"
    assert_equal [ "Salesview 2", apps(:kpi) ], [ entry.reload.name, entry.app ]
    assert_empty entry.links
    changes = audit("index.entry.updated").data["changes"]
    assert_equal [ "Salesview", "Salesview 2" ], changes["name"]
    assert_equal [ [ "Booking admin https://salesview.app.journeybooking.eu/admin" ], [] ], changes["links"]
    assert_equal apps(:kpi), audit("index.entry.updated").app, "the audit log can be filtered by the tied app"
  end

  test "a failed rename still posts to the existing url, and keeps its groups" do
    index_entries(:salesview).update!(visibility: "groups", groups: [ groups(:ro_dev) ])
    patch "/index/entries/salesview", params: { index_entry: { slug: "Not A Slug!", group_ids: [ "", groups(:dk_tech).id.to_s ] } }
    assert_response :unprocessable_content
    assert_select "form[action=?]", "/index/entries/salesview"
    assert_equal [ "RO Dev" ], index_entries(:salesview).reload.groups.map(&:name), "nothing saved"
  end

  test "delete an entry, audited" do
    assert_difference -> { Index::Entry.count } => -1 do
      delete "/index/entries/salesview"
    end
    assert_redirected_to "/index/entries"
    assert_equal({ "slug" => "salesview", "name" => "Salesview" }, audit("index.entry.deleted").data)
  end

  test "sections: add a table one for a group, change its visibility, delete keeps its entries" do
    post "/index/sections", params: { index_section: { name: "Monitoring", layout: "table", visibility: "groups",
                                                       group_ids: [ "", groups(:ro_devops).id.to_s ] } }
    assert_redirected_to "/index/sections"
    section = Index::Section.find_by!(slug: "monitoring")
    assert section.table?
    assert_equal [ "RO DevOps" ], section.groups.map(&:name)
    assert_equal [ "RO DevOps" ], audit("index.section.created").data["groups"]

    patch "/index/sections/monitoring", params: { index_section: { visibility: "everyone", group_ids: [ "", groups(:ro_devops).id.to_s ] } }
    assert_redirected_to "/index/sections"
    assert_empty section.reload.groups, "everyone means no groups"
    assert_equal [ [ "RO DevOps" ], [] ], audit("index.section.updated").data["changes"]["groups"]

    delete "/index/sections/databases"
    assert_nil index_entries(:sql_bravo).reload.section
    assert_equal 1, audit("index.section.deleted").data["entries"]
  end

  test "vocabularies: add, rename and delete an access level, audited" do
    post "/index/access_levels", params: { index_access_level: { label: "Tailscale", tone: "ok" } }
    assert_redirected_to "/index/access_levels"
    level = Index::AccessLevel.find_by!(key: "tailscale")
    assert_equal "index.access_level.created", AuditEvent.last.action
    patch "/index/access_levels/#{level.id}", params: { index_access_level: { label: "Tailscale VPN" } }
    assert_equal [ "Tailscale", "Tailscale VPN" ], audit("index.access_level.updated").data["changes"]["label"]
    delete "/index/login_methods/#{index_login_methods(:sso).id}"
    assert_nil index_entries(:salesview).reload.login_method
    assert_equal "index.login_method.deleted", AuditEvent.last.action
  end

  test "docs: write one, served at its section path, audited without the body" do
    post "/index/docs", params: { index_doc: { title: "Rolling back", doc_section_id: index_doc_sections(:deployment).id, body: "## How\n\nRedeploy." } }
    doc = Index::Doc.find_by!(slug: "rolling-back")
    assert_redirected_to "/index/docs/#{doc.id}/edit"
    patch "/index/docs/#{doc.id}", params: { index_doc: { body: "## How\n\nRedeploy the previous image." } }
    assert_equal({ "body" => "changed" }, audit("index.doc.updated").data["changes"])

    reset!
    sign_in_index users(:alice), path: "/docs/deployment/rolling-back"
    assert_response :success
    assert_select "h1", "Rolling back"
  end

  test "doc sections: shown to all staff or to the chosen groups, audited" do
    get "/index/doc_sections/#{index_doc_sections(:deployment).id}/edit"
    assert_select "select[name='index_doc_section[visibility]'] option[selected]", "All Tourpaq staff"
    post "/index/doc_sections", params: { index_doc_section: { title: "Runbooks", visibility: "groups",
                                                               group_ids: [ "", groups(:ro_devops).id.to_s ] } }
    section = Index::DocSection.find_by!(key: "runbooks")
    assert_equal [ "groups", [ "RO DevOps" ] ], [ section.visibility, section.groups.map(&:name) ]
    assert_equal [ "RO DevOps" ], audit("index.doc_section.created").data["groups"]

    patch "/index/doc_sections/#{section.id}", params: { index_doc_section: { visibility: "everyone", group_ids: [ "", groups(:ro_devops).id.to_s ] } }
    assert_redirected_to "/index/doc_sections"
    assert_empty section.reload.groups, "all staff means no groups"
    changes = audit("index.doc_section.updated").data["changes"]
    assert_equal [ [ "groups", "everyone" ], [ [ "RO DevOps" ], [] ] ], changes.values_at("visibility", "groups")
    get "/index/doc_sections"
    assert_select "td", "All Tourpaq staff"
  end

  test "doc sections and site settings, audited" do
    post "/index/doc_sections", params: { index_doc_section: { title: "Runbooks" } }
    assert_redirected_to "/index/doc_sections"
    assert Index::DocSection.exists?(key: "runbooks")
    assert_equal "index.doc_section.created", AuditEvent.last.action

    patch "/index/site", params: { index_site: { title: "Tourpaq Index" } }
    assert_redirected_to "/index/site/edit"
    assert_equal [ "Tourpaq DK Home", "Tourpaq Index" ], audit("index.site.updated").data["changes"]["title"]
    reset!
    sign_in_index users(:alice)
    assert_select ".ix-hero h1", "Tourpaq Index"
  end
end
