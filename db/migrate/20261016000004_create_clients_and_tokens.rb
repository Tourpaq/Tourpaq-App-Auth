class CreateClientsAndTokens < ActiveRecord::Migration[8.1]
  def change
    # §7.4. kind: web (confidential), extension (public, PKCE) or internal (the admin host's own
    # client "admin", §11.2: no app, no secret, served in-process).
    create_table :clients do |t|
      t.references :app, foreign_key: true # NULL only for the internal admin client
      t.string :client_id, null: false
      t.string :kind, null: false, default: "web"
      t.string :name
      t.json :redirect_uris, null: false, default: []
      t.json :post_logout_redirect_uris, null: false, default: []
      t.datetime :disabled_at
      t.timestamps
    end
    add_index :clients, :client_id, unique: true

    # At most two active per client (rotation without downtime). Shown once, stored as SHA-256.
    create_table :client_secrets do |t|
      t.references :client, null: false, foreign_key: true
      t.string :secret_digest, null: false
      t.string :hint, null: false
      t.datetime :expires_at
      t.datetime :last_used_at
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :client_secrets, :secret_digest, unique: true

    # §7.2: single use, 60 seconds.
    create_table :authorization_codes do |t|
      t.references :client, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :session, foreign_key: true # the home session that authorized it
      t.string :code_digest, null: false
      t.string :redirect_uri, null: false
      t.string :code_challenge
      t.string :code_challenge_method
      t.string :nonce
      t.string :scope
      t.datetime :auth_time # the Entra sign-in behind it (ID token auth_time)
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.datetime :created_at, null: false
    end
    add_index :authorization_codes, :code_digest, unique: true
    add_index :authorization_codes, :expires_at

    # §10: extension access tokens (tpx_<slug>_…, 1 hour) and rotating refresh tokens. A chain_id
    # groups a refresh token with all its successors, so a reused one revokes the whole chain.
    create_table :oauth_tokens do |t|
      t.references :client, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :kind, null: false # access | refresh
      t.string :token_digest, null: false
      t.string :token_hint
      t.string :scope
      t.string :chain_id, null: false
      t.references :replaced_by, foreign_key: { to_table: :oauth_tokens }
      t.datetime :auth_time
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.timestamps
    end
    add_index :oauth_tokens, :token_digest, unique: true
    add_index :oauth_tokens, :chain_id
    add_index :oauth_tokens, [ :user_id, :revoked_at ]

    # §9: tpa_<slug>_…, one app per token, scope read | read_write.
    create_table :personal_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.references :app, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_hint, null: false
      t.string :scope, null: false, default: "read"
      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.references :revoked_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :personal_tokens, :token_digest, unique: true
    add_index :personal_tokens, [ :user_id, :revoked_at, :expires_at ]

    # §12: access checks and introspections are counted per client and day, not audited.
    create_table :usage_counts do |t|
      t.references :client, null: false, foreign_key: true
      t.date :day, null: false
      t.string :kind, null: false # access | introspect
      t.integer :count, null: false, default: 0
    end
    add_index :usage_counts, [ :client_id, :day, :kind ], unique: true
  end
end
