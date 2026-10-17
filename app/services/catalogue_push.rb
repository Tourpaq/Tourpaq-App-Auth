# An app's permission catalogue (SPECS.md §23.2), pushed by the app itself with PUT /api/v1/catalogue at boot or
# deploy. A push replaces the whole catalogue; keys that roles still hold but the catalogue no longer has are
# flagged as unknown (and still sent to the app), never removed from the roles.
#
#   result = CataloguePush.call(app, [ { "key" => "module:customers:view", "label" => "Customers", "group" => "Modules" } ])
#   result.added / result.removed / result.changed   # keys
#   result.unknown                                    # { "Role name" => ["old:key"] } after the push
#   CataloguePush::Invalid                            # the list is malformed: nothing changed
#
# Audited app.catalogue_pushed (added, removed and relabelled keys, the count and the unknown keys) when anything
# changed; an identical push only records the time (catalogue_pushed_at), so a boot-time push is not noise.
class CataloguePush
  MAX_ENTRIES = 2000

  class Invalid < StandardError; end

  Result = Data.define(:app, :count, :added, :removed, :changed, :unknown) do
    def changed? = added.any? || removed.any? || changed.any?

    def as_json(*)
      { app: app.slug, count: count, added: added, removed: removed, changed: changed,
        unknown: unknown.map { |role, keys| { role: role, permissions: keys } } }
    end
  end

  def self.call(app, entries) = new(app, entries).call

  def initialize(app, entries)
    @app = app
    @entries = normalize(entries)
  end

  def call
    existing = @app.catalogue.to_a.index_by(&:key)
    first_push = !@app.catalogue_pushed?
    keys = @entries.map { _1[:key] }
    added = keys - existing.keys
    removed = existing.keys - keys
    changed = @entries.select { |e| (row = existing[e[:key]]) && (row.label != e[:label] || row.group_label != e[:group_label]) }.map { _1[:key] }

    App.transaction do
      @app.catalogue.where(key: removed).delete_all if removed.any?
      @entries.each_with_index do |entry, index|
        row = existing[entry[:key]] || @app.catalogue.build(key: entry[:key])
        row.assign_attributes(label: entry[:label], group_label: entry[:group_label], position: index + 1)
        row.save! if row.new_record? || row.changed?
      end
      @app.update_columns(catalogue_pushed_at: Time.current, updated_at: Time.current)
      @app.catalogue.reset
      @result = Result.new(app: @app, count: keys.size, added: added.sort, removed: removed.sort, changed: changed.sort,
                           unknown: @app.unknown_permissions.to_h { |role, unknown| [ role.key, unknown ] })
      if @result.changed? || first_push
        AuditEvent.record("app.catalogue_pushed", subject: @app, actor: nil,
                          data: { count: keys.size, added: @result.added, removed: @result.removed, changed: @result.changed,
                                  unknown: @result.unknown })
      end
    end
    @result
  end

  private

  def normalize(entries)
    raise Invalid, "permissions must be a list" unless entries.is_a?(Array)
    raise Invalid, "at most #{MAX_ENTRIES} permissions" if entries.size > MAX_ENTRIES
    list = entries.map.with_index do |entry, index|
      raise Invalid, "permission #{index + 1} is not an object" unless entry.is_a?(Hash)
      entry = entry.transform_keys(&:to_s)
      key = entry["key"]
      unless key.is_a?(String) && key.length <= 100 && key.match?(AppRole::PERMISSION_FORMAT)
        raise Invalid, "permission #{index + 1} has no valid key (letters, digits, _ . - separated by colons)"
      end
      label = text(entry["label"], index, "label")
      group = text(entry.key?("group") ? entry["group"] : entry["group_label"], index, "group")
      { key: key, label: label, group_label: group }
    end
    duplicates = list.map { _1[:key] }.tally.select { |_, n| n > 1 }.keys
    raise Invalid, "duplicate keys: #{duplicates.first(5).join(', ')}" if duplicates.any?
    list
  end

  def text(value, index, name)
    return nil if value.nil?
    raise Invalid, "permission #{index + 1}: #{name} must be a string of at most 200 characters" unless value.is_a?(String) && value.length <= 200
    value.strip.presence
  end
end
