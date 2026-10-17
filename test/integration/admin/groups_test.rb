require "test_helper"

# Admin: groups, members, grants (SPECS.md §5.2, §5.3, §11.2, §12).
class Admin::GroupsTest < ActionDispatch::IntegrationTest
  setup { sign_in_admin users(:mwi) }

  test "list and page" do
    get "/groups"
    assert_response :success
    assert_select "td a", "RO Dev"
    get "/groups/#{groups(:ro_dev).id}"
    assert_response :success
    assert_select "h1", "RO Dev"
    assert_select ".access-table td", /responder/
    assert_select "td a", "Alice Popescu"
  end

  test "create, rename and delete a group, audited" do
    get "/groups/new"
    assert_response :success
    post "/groups", params: { group: { name: "RO QA", description: "Testers" } }
    group = Group.find_by!(name: "RO QA")
    assert_redirected_to "/groups/#{group.id}"
    assert_equal({ "name" => "RO QA" }, audit("group.created").data)

    get "/groups/#{group.id}/edit"
    assert_response :success
    patch "/groups/#{group.id}", params: { group: { name: "RO Quality" } }
    assert_redirected_to "/groups/#{group.id}"
    assert_equal({ "changes" => { "name" => "RO Quality" } }, audit("group.updated").data)

    post "/groups", params: { group: { name: "ro quality" } }
    assert_response :unprocessable_entity, "names are unique, ignoring case"

    delete "/groups/#{group.id}"
    assert_redirected_to "/groups"
    assert_not Group.exists?(group.id)
    assert_equal "RO Quality", audit("group.deleted").data["name"]
  end

  test "deleting a group removes its grants first, each audited with the members' roles" do
    group = groups(:ro_dev)
    delete "/groups/#{group.id}"
    assert_not Grant.exists?(subject_type: "Group", subject_id: group.id)
    event = audit("grant.removed")
    assert_equal [ group.id, apps(:irm) ], [ event.subject_id, event.app ]
    assert_includes event.data["users"], { "user_id" => users(:alice).id, "email" => "alice@tourpaq.com", "before" => "responder", "after" => nil }
    assert_not EffectiveRole.for(users(:alice), apps(:irm)).access?
  end

  test "add and remove members, audited with what changes for them" do
    bob = users(:bob)
    post "/groups/#{groups(:ro_dev).id}/members", params: { user_id: bob.id }
    assert_redirected_to "/groups/#{groups(:ro_dev).id}"
    assert_includes groups(:ro_dev).users.reload, bob
    event = audit("group.member_added")
    assert_equal groups(:ro_dev), event.subject
    assert_equal [ { "user_id" => bob.id, "email" => "bob@tourpaq.com", "before" => nil, "after" => "responder", "app" => "irm" } ], event.data["access"]
    assert_not bob.reload.pending?

    post "/groups/#{groups(:ro_dev).id}/members", params: { user_id: bob.id }
    assert_match "already in", flash[:alert]

    delete "/groups/#{groups(:ro_dev).id}/members/#{bob.id}"
    assert_not_includes groups(:ro_dev).users.reload, bob
    assert_equal "responder", audit("group.member_removed").data["access"].first["before"]
  end

  test "losing an app through a group revokes that app's extension tokens (§6)" do
    refresh = create_extension_sign_in(users(:alice))
    delete "/groups/#{groups(:ro_dev).id}/members/#{users(:alice).id}"
    assert refresh.reload.revoked?
  end

  test "add a user to a group from the user's page" do
    post "/users/#{users(:bob).id}/groups", params: { group_id: groups(:ro_devops).id }
    assert_redirected_to "/users/#{users(:bob).id}"
    assert_includes users(:bob).groups.reload, groups(:ro_devops)
    delete "/groups/#{groups(:ro_devops).id}/members/#{users(:bob).id}", params: { back: "user" }
    assert_redirected_to "/users/#{users(:bob).id}"
  end
end

class Admin::GrantsTest < ActionDispatch::IntegrationTest
  setup { sign_in_admin users(:mwi) }

  test "grant an app to a group: created, with every member's before and after" do
    post "/grants", params: { app_id: apps(:kpi).id, subject_type: "Group", subject_id: groups(:ro_dev).id, role: "viewer" }
    assert_redirected_to "/groups/#{groups(:ro_dev).id}"
    assert_equal "viewer", EffectiveRole.for(users(:alice), apps(:kpi)).role_key
    event = audit("grant.created")
    assert_equal [ groups(:ro_dev), apps(:kpi), users(:mwi) ], [ event.subject, event.app, event.actor ]
    assert_same_value nil, event.data["role_before"]
    assert_equal "viewer", event.data["role_after"]
    assert_equal [ { "user_id" => users(:alice).id, "email" => "alice@tourpaq.com", "before" => nil, "after" => "viewer" } ],
                 event.data["users"], "only active members"
  end

  test "change a group's role: changed" do
    post "/grants", params: { app_id: apps(:irm).id, subject_type: "Group", subject_id: groups(:ro_dev).id, role: "editor" }
    event = audit("grant.changed")
    assert_equal [ "responder", "editor" ], [ event.data["role_before"], event.data["role_after"] ]
    assert_equal [ "responder", "editor" ], event.data["users"].first.values_at("before", "after")
  end

  test "setting the same role again records nothing" do
    assert_no_difference -> { AuditEvent.count } do
      post "/grants", params: { app_id: apps(:irm).id, subject_type: "Group", subject_id: groups(:ro_dev).id, role: "responder" }
    end
  end

  test "a direct grant to a user overrides the groups, also as no access" do
    alice = users(:alice)
    post "/grants", params: { app_id: apps(:irm).id, subject_type: "User", subject_id: alice.id, role: "admin" }
    assert_redirected_to "/users/#{alice.id}"
    assert_equal "admin, direct", EffectiveRole.for(alice, apps(:irm)).to_s
    assert_equal [ { "user_id" => alice.id, "email" => alice.email, "before" => "responder", "after" => "admin" } ], audit("grant.created").data["users"]

    refresh = create_extension_sign_in(alice)
    post "/grants", params: { app_id: apps(:irm).id, subject_type: "User", subject_id: alice.id, role: "none" }
    assert_equal "no access (direct)", EffectiveRole.for(alice, apps(:irm)).to_s
    event = audit("grant.changed")
    assert_equal [ "admin", "no access" ], [ event.data["role_before"], event.data["role_after"] ]
    assert_equal [ "admin", nil ], event.data["users"].first.values_at("before", "after")
    assert refresh.reload.revoked?, "losing access revokes the app's extension tokens"

    grant = Grant.find_by!(app: apps(:irm), subject: alice)
    delete "/grants/#{grant.id}"
    assert_redirected_to "/users/#{alice.id}"
    assert_equal "responder, from RO Dev", EffectiveRole.for(alice, apps(:irm)).to_s
    event = audit("grant.removed")
    assert_equal [ "no access", nil ], [ event.data["role_before"], event.data["role_after"] ]
    assert_equal [ nil, "responder" ], event.data["users"].first.values_at("before", "after")
  end

  test "no access is for users only, and the role must belong to the app" do
    assert_no_difference -> { Grant.count } do
      post "/grants", params: { app_id: apps(:kpi).id, subject_type: "Group", subject_id: groups(:ro_dev).id, role: "none" }
    end
    assert_match "required for a group grant", flash[:alert]
    post "/grants", params: { app_id: apps(:kpi).id, subject_type: "Group", subject_id: groups(:ro_dev).id, role: "responder" }
    assert_match "Pick a role of KPI", flash[:alert]
    post "/grants", params: { app_id: apps(:kpi).id, subject_type: "App", subject_id: apps(:irm).id, role: "viewer" }
    assert_response :not_found
  end
end
