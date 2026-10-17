# Permission-carrying roles and per-app token scopes (SPECS.md §23.2, §23.3):
#
# - apps.multiple_roles: a user may hold several roles in the app (the union counts);
# - apps.admin_permission: the key the per-app last-administrator guard protects (Dashboard: admin:access:manage);
# - apps.token_scopes: the app's ordered personal-token scopes, lowest first (default read < read_write);
# - apps.catalogue_pushed_at: when the app last pushed its permission catalogue (PUT /api/v1/catalogue);
# - app_permissions: that catalogue (key, label, group label), replaced by every push;
# - app_roles.permissions: the role's permission keys, or "*";
# - grants: unique per (app, subject, role) instead of (app, subject), so a subject can hold several roles of a
#   multiple-roles app. One role per subject in other apps, and a "no access" grant excluding every other grant
#   of the user in that app, are model rules (Grant).
class AddPermissionRolesAndTokenScopes < ActiveRecord::Migration[8.1]
  def change
    change_table :apps, bulk: true do |t|
      t.boolean :multiple_roles, null: false, default: false
      t.string :admin_permission
      t.json :token_scopes, null: false, default: %w[read read_write]
      t.datetime :catalogue_pushed_at
    end

    add_column :app_roles, :permissions, :json, null: false, default: []

    create_table :app_permissions do |t|
      t.references :app, null: false, foreign_key: true
      t.string :key, null: false
      t.string :label
      t.string :group_label
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :app_permissions, [ :app_id, :key ], unique: true

    remove_index :grants, [ :app_id, :subject_type, :subject_id ], unique: true
    add_index :grants, [ :app_id, :subject_type, :subject_id, :app_role_id ], unique: true, name: "index_grants_on_app_subject_and_role"
  end
end
