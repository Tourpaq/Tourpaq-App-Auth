require "json"

module TourpaqAuth
  # A permission app's catalogue (SPECS.md §23.2): every permission the app checks, with a label and a group label,
  # pushed to the auth app with PUT /api/v1/catalogue at boot or deploy. Each push replaces the stored catalogue.
  # The auth app's role editor shows it as checkboxes and flags role keys that are not in it.
  #
  #   result = TourpaqAuth::Catalogue.push([
  #     { key: "module:customers:view", label: "Customers", group: "Modules" },
  #     { key: "admin:access:manage", label: "Access management", group: "Administration" }
  #   ])
  #   result.count, result.added, result.removed, result.changed   # keys
  #   result.unknown    # { "Support" => ["old:key"] }: role keys the catalogue no longer has
  #
  # Entries are hashes (key, label, group or group_label; symbol or string keys) or objects answering key and
  # optionally label and group (or group_label). Raises TourpaqAuth::Unavailable (outage: retry later) or
  # TourpaqAuth::Refused (wrong credentials, a malformed list: status 400, with the reason).
  module Catalogue
    Result = Data.define(:app, :count, :added, :removed, :changed, :unknown)

    module_function

    def push(entries)
      permissions = Array(entries).map { entry(_1) }
      status, body = Api.call(:put, "/api/v1/catalogue", body: JSON.generate(permissions: permissions),
                                                         headers: { "Content-Type" => "application/json" })
      Api.refused!(status, body) unless status == 200
      json = Http.parse_json(body)
      raise Error, "The catalogue answer is not an object" unless json.is_a?(Hash)
      Result.new(app: json["app"], count: json["count"].to_i, added: Array(json["added"]), removed: Array(json["removed"]),
                 changed: Array(json["changed"]),
                 unknown: Array(json["unknown"]).to_h { [ _1["role"], Array(_1["permissions"]) ] })
    end

    def entry(value)
      if value.is_a?(Hash)
        fields = value.transform_keys(&:to_s)
        { key: fields["key"].to_s, label: fields["label"], group: fields.key?("group") ? fields["group"] : fields["group_label"] }
      elsif value.respond_to?(:key)
        group = value.respond_to?(:group) ? value.group : (value.respond_to?(:group_label) ? value.group_label : nil)
        { key: value.key.to_s, label: value.respond_to?(:label) ? value.label : nil, group: group }
      else
        { key: value.to_s, label: nil, group: nil }
      end.transform_values { _1.nil? ? nil : _1.to_s }
    end
  end
end
