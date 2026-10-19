require "test_helper"

# The app page's "how access works" box and the standard roles button (StarterRoles, SPECS.md §23.2).
class Admin::StarterRolesTest < ActionDispatch::IntegrationTest
  setup do
    @dash = create_dashboard_app(roles: false)
    sign_in_admin users(:mwi)
  end

  test "an app without roles: the how-to box and the standard roles, DK Tech ticked" do
    get "/apps/#{@dash.id}"
    assert_response :success
    assert_select ".how-access h2", "How access to Dashboard works"
    assert_select ".how-access a[href='/groups']"
    assert_select ".how-access a[href='/users/new']"
    assert_equal [ "Admin", "Management", "Staff" ], css_select(".starter-roles .starter-list li strong").map(&:text)
    assert_select ".starter-roles .pill-warn", "everything (*)"
    assert_select ".starter-roles li", /Customers, Tasks/ # catalogue labels, not keys
    assert_select ".starter-roles input[type=checkbox][name=admin_group][checked]"
    assert_select ".starter-roles", /DK Tech/
    assert_select "td.empty", /use the standard roles above/
  end

  test "creating them: the roles with the keys the catalogue knows, audited, and DK Tech gets everything" do
    post "/apps/#{@dash.id}/roles/starter", params: { admin_group: "1" }
    assert_redirected_to "/apps/#{@dash.id}"
    assert_equal "Added Admin, Management, and Staff. DK Tech now has Admin.", flash[:notice]

    @dash.reload
    assert_equal [ "Admin", "Management", "Staff" ], @dash.role_keys.sort
    assert_equal [ "*" ], @dash.role("Admin").permissions
    # module:dashboard:view and the others are not in this test catalogue, so they are left out.
    assert_equal %w[management:finance:view module:customers:view module:tasks:view], @dash.role("Management").permissions
    assert_equal %w[module:customers:view module:tasks:view], @dash.role("Staff").permissions
    assert_empty @dash.unknown_permissions

    added = AuditEvent.where(action: "app.role_added").order(:id).last(3)
    assert_equal [ "Admin", "Management", "Staff" ], added.map { _1.data["key"] }
    assert added.all? { _1.data["via"] == "starter_roles" }
    assert_equal "DK Tech", audit("grant.created").subject.name

    assert_equal [ "*" ], EffectiveRole.for(users(:mwi), @dash).permissions
    assert_equal [ "*" ], EffectiveRole.for(users(:jjr), @dash).permissions
    assert_empty Array(EffectiveRole.for(users(:alice), @dash)&.permissions)

    get "/apps/#{@dash.id}"
    assert_select ".starter-roles", count: 0
    assert_select ".how-access"
  end

  test "without the tick DK Tech gets nothing" do
    post "/apps/#{@dash.id}/roles/starter"
    assert_equal "Added Admin, Management, and Staff.", flash[:notice]
    assert_not Grant.exists?(app: @dash)
  end

  test "only the missing roles are added; an existing one (any case) is not touched" do
    @dash.add_role!("staff", description: "Ours", permissions: %w[module:tasks:view])
    get "/apps/#{@dash.id}"
    assert_equal [ "Admin", "Management" ], css_select(".starter-roles .starter-list li strong").map(&:text)

    post "/apps/#{@dash.id}/roles/starter"
    @dash.reload
    assert_equal [ "Admin", "Management", "staff" ], @dash.role_keys.sort
    assert_equal [ "Ours", %w[module:tasks:view] ], [ @dash.role("staff").description, @dash.role("staff").permissions ]

    post "/apps/#{@dash.id}/roles/starter"
    assert_equal "Dashboard already has the standard roles.", flash[:notice]
    assert_equal 3, @dash.roles.count
  end

  test "the DK Tech box is not offered when the admin role exists already" do
    @dash.add_role!("Admin", permissions: [ "*" ])
    get "/apps/#{@dash.id}"
    assert_equal [ "Management", "Staff" ], css_select(".starter-roles .starter-list li strong").map(&:text)
    assert_select ".starter-roles input[name=admin_group]", count: 0
  end

  test "an app without standard roles: no card, and the button is refused" do
    get "/apps/#{apps(:irm).id}"
    assert_select ".starter-roles", count: 0
    assert_select ".how-access", count: 0 # single-role app

    post "/apps/#{apps(:irm).id}/roles/starter"
    assert_redirected_to "/apps/#{apps(:irm).id}"
    assert_equal "IRM has no standard roles.", flash[:alert]
  end

  test "before the catalogue is pushed the definitions are used as they are" do
    app = @dash
    app.update_columns(catalogue_pushed_at: nil)
    AppPermission.where(app: app).delete_all
    staff = StarterRoles.for(app.reload).find { _1.key == "Staff" }
    assert_equal %w[module:dashboard:view module:customers:view module:tasks:view], staff.permissions
  end
end
