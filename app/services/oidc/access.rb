# May this user sign in to this client, and with which role (SPECS.md §7.2, §11.2)?
#
#   Oidc::Access.allowed?(user, client)   # active user, active client/app, and a role in the app
#   Oidc::Access.role_key(user, client)   # "responder", or nil (a multiple-roles app's roles and permissions
#                                         # come from EffectiveRole; Oidc::IdToken.user_claims)
#   Oidc::Access.app_name(client)         # for the "no access" page: "IRM", "Tourpaq Auth admin"
#
# The internal clients belong to no app: for "admin" (the admin host) access means being an active admin,
# for "index" (the index host, §24.1) being an active user (a pending user is then sent to "waiting for
# access" by the index host). Every other client's access is the user's effective role in the client's app (§5.3).
module Oidc
  module Access
    module_function

    def allowed?(user, client)
      return false unless user&.active? && client&.active?
      return user.admin? if client.admin_client?
      return true if client.index_client?
      return false if client.internal?
      EffectiveRole.for(user, client.app).access?
    end

    def role_key(user, client)
      return nil if client.nil? || client.internal?
      EffectiveRole.for(user, client.app).role_key
    end

    def app_name(client)
      return "Tourpaq Auth admin" if client.admin_client?
      return "the Tourpaq index" if client.index_client?
      client.app&.name || client.client_id
    end
  end
end
