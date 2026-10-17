class CreateUsersAndSessions < ActiveRecord::Migration[8.1]
  def change
    # SPECS.md §4. `sub` is the public subject the apps see; Entra's oid + tid are the sign-in key.
    create_table :users do |t|
      t.string :sub, null: false
      t.string :entra_oid
      t.string :entra_tid
      t.string :email, null: false # stored lowercase (User normalizes), unique
      t.string :name
      t.string :upn
      t.boolean :admin, null: false, default: false
      t.datetime :disabled_at
      t.datetime :sessions_valid_after
      t.datetime :last_login_at
      t.timestamps
    end
    add_index :users, :sub, unique: true
    add_index :users, :email, unique: true
    add_index :users, [ :entra_oid, :entra_tid ], unique: true

    # Signed-in browsers at the auth app itself (§3.3), and the admin host's own sessions (§11.2):
    # kind "home" or "admin". The cookie holds the token; only its SHA-256 is stored.
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false, default: "home"
      t.string :token_digest, null: false
      t.string :ip_address
      t.string :user_agent
      t.datetime :entra_authenticated_at, null: false # the Entra sign-in behind it (auth_time)
      t.datetime :last_seen_at, null: false
      t.datetime :ended_at
      t.string :end_reason # signed_out, idle, expired, disabled, signed_out_everywhere, not_admin, …
      t.timestamps
    end
    add_index :sessions, :token_digest, unique: true
    add_index :sessions, [ :user_id, :kind, :ended_at ]
  end
end
