module TourpaqAuth
  # What a permission app (SPECS.md §23.2) gets for a user: the role names they hold (`roles`) and the sorted union
  # of those roles' permissions (`permissions`), where "*" means everything. Mixed into TourpaqAuth::Login,
  # TourpaqAuth::Access::Result and ::Member, and TourpaqAuth::Tokens::Result. For a single-role app `roles` is
  # [role] (or []) and `permissions` is [].
  #
  #   result.permission?("module:customers:view")   # true through the key or "*"
  #   result.role?("Administrators")
  module Permissions
    WILDCARD = "*".freeze

    def permission?(key) = permissions.include?(WILDCARD) || permissions.include?(key.to_s)
    def role?(name) = roles.include?(name.to_s)

    # [role] for a single role, the list for a permission app; strings, no blanks.
    def self.role_list(roles, role)
      list = roles.nil? ? [ role ] : Array(roles)
      list.compact.map { _1.to_s.strip }.reject(&:empty?).freeze
    end

    def self.list(values) = Array(values).compact.map(&:to_s).freeze
  end
end
