require "test_helper"

# The index's pages on the index host (SPECS.md §24.3; WWW's public pages): sections, entry pages, docs, search, and
# that every one of them shows only what the viewer may see.
class Index::PagesTest < ActionDispatch::IntegrationTest
  test "a table section is a compact table with copyable addresses and the gaps shown" do
    sign_in_index users(:mwi), path: "/groups/databases"
    assert_response :success
    assert_select "h1", "Databases"
    assert_select ".ix-table code[data-index-copy-text-value=?]", "sql-bp-we-01.tourpaq.com"
    assert_select ".ix-table .ix-access.ix-tone-unset", text: "Login?"
  end

  test "a cards section is cards, with a filter once it is long" do
    6.times { |i| Index::Entry.create!(name: "Tool #{i}", description: "A tool.", url: "https://tool#{i}.example", section: index_sections(:apps)) }
    sign_in_index users(:alice), path: "/groups/apps"
    assert_select ".ix-card", 8
    assert_select "[data-controller='index-filter'] input[data-index-filter-target='input']"
  end

  test "a section the viewer may not see is a 404, as an unknown one" do
    sign_in_index users(:alice), path: "/groups/databases"
    assert_response :not_found
    get "/groups/nope"
    assert_response :not_found
  end

  test "an entry's details page renders its markdown and facts" do
    sign_in_index users(:mwi), path: "/apps/ms-sql-master-bravo"
    assert_response :success
    assert_select ".ix-prose h2#connecting"
    assert_select ".ix-facts code", "sql-bp-we-01.tourpaq.com"
    assert_select "a[href='http://admin.example.com/index/entries/ms-sql-master-bravo/edit']", "Edit"
  end

  test "an app's entry page shows the viewer's role; no edit link for non-admins" do
    sign_in_index users(:alice), path: "/apps/irm"
    assert_select ".ix-facts .badge.role-responder"
    assert_select "a", { text: "Edit", count: 0 }
  end

  test "entry pages of another app, another group or a hidden section are 404" do
    sign_in_index users(:alice), path: "/apps/ms-sql-master-bravo"
    assert_response :not_found
    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: nil)
    get "/apps/irm"
    assert_response :not_found
    get "/apps/nope"
    assert_response :not_found
  end

  test "markdown cannot run script on an entry page" do
    index_entries(:salesview).update!(body: %(Hi <script>alert(1)</script><img src=x onerror="alert(1)"> [x](javascript:alert(1))))
    sign_in_index users(:alice), path: "/apps/salesview"
    assert_response :success
    assert_not_includes response.body, "<script>alert"
    assert_not_includes response.body, "onerror"
    assert_not_includes response.body, "javascript:alert"
  end

  test "docs render with a table of contents, in or out of a section" do
    sign_in_index users(:alice), path: "/docs/deployment/deploying-a-new-app"
    assert_response :success
    assert_select ".ix-toc .ix-toc-item", 3
    Index::Doc.create!(title: "Loose page", body: "Hello")
    get "/docs/loose-page"
    assert_response :success
    assert_select "h1", "Loose page"
    get "/docs/deployment/nope"
    assert_response :not_found
  end

  test "search: the page and the json index, both limited to what the viewer may see" do
    sign_in_index users(:mwi), path: "/search?q=bravo+sql"
    assert_response :success
    assert_select ".ix-table .ix-row-title", text: "MS SQL Master - Bravo"
    get "/search.json"
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"], "never served to the next user of this browser"
    names = response.parsed_body.map { |e| e["name"] }
    assert_includes names, "Salesview"
    assert_includes names, "MS SQL Master - Bravo"
    assert_includes names, "App deployment"

    reset!
    sign_in_index users(:alice), path: "/search?q=bravo+sql"
    assert_select ".ix-table .ix-row-title", { text: "MS SQL Master - Bravo", count: 0 }
    assert_select ".empty", /Nothing matches/
    get "/search.json"
    names = response.parsed_body.map { |e| e["name"] }
    assert_equal [ "IRM", "Salesview", "App deployment" ].sort, names.sort
  end

  test "external icons may load on the index's pages; scripts stay strict" do
    sign_in_index users(:alice)
    csp = response.headers["Content-Security-Policy"]
    assert_match(/img-src 'self' data: https:/, csp)
    assert_match(/script-src 'self'/, csp)
    assert_no_match(/script-src[^;]*https:/, csp)
  end

  test "the sidebar holds the search box and the visible sections with their counts" do
    sign_in_index users(:mwi)
    assert_select ".sidebar form.ix-nav-search[action='/search'] input[name=q]"
    assert_select ".sidebar a.ix-nav-item[href='/groups/apps'] .ix-nav-count", "2"
    assert_select ".sidebar a.ix-nav-item[href='/docs/deployment/deploying-a-new-app']", "App deployment"
    get "/profile"
    assert_select ".sidebar a.ix-nav-item[href='/groups/apps']", 1, "the navigation is on every index page"
  end
end
