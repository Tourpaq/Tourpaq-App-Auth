class CreateGroupsAppsAndGrants < ActiveRecord::Migration[8.1]
  def change
    # §5.2
    create_table :groups do |t|
      t.string :name, null: false
      t.text :description
      t.timestamps
    end
    add_index :groups, :name, unique: true

    create_table :group_memberships do |t|
      t.references :group, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :group_memberships, [ :group_id, :user_id ], unique: true

    # §5.1
    create_table :apps do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.text :description
      t.string :icon
      t.string :url
      t.string :role_claim, null: false
      t.boolean :show_in_launcher, null: false, default: true
      t.datetime :disabled_at
      t.timestamps
    end
    add_index :apps, :slug, unique: true

    # Ordered roles, lowest first (position 1 = lowest).
    create_table :app_roles do |t|
      t.references :app, null: false, foreign_key: true
      t.string :key, null: false
      t.string :description
      t.integer :position, null: false
      t.timestamps
    end
    add_index :app_roles, [ :app_id, :key ], unique: true
    add_index :app_roles, [ :app_id, :position ], unique: true

    # §5.3: (app, user or group) → role; app_role_id NULL = "no access" (users only).
    create_table :grants do |t|
      t.references :app, null: false, foreign_key: true
      t.references :subject, polymorphic: true, null: false
      t.references :app_role, foreign_key: true
      t.timestamps
    end
    add_index :grants, [ :app_id, :subject_type, :subject_id ], unique: true
  end
end
