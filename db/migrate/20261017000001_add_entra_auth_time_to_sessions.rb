# When the person last gave Entra their credentials: the auth_time claim of Entra's ID token (SPECS.md §3.3).
# It decides prompt=login and max_age (§7.6) and the admin host's 12 hours (§11.2). entra_authenticated_at stays
# the time of the Entra sign-in behind the session (silent or not), from which the session's lifetime counts.
class AddEntraAuthTimeToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :entra_auth_time, :datetime
  end
end
