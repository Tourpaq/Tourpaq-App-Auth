module TourpaqAuth
  # The authorization API (SPECS.md §8): "does this user still have access to this app, with which role?"
  # and "who has access to this app?".
  module Access
    # One user's access. active? false means: end their session. stale? true means the auth app could
    # not be reached and this is the last known answer, still inside the grace period. A permission app
    # (SPECS.md §23.2) gets role nil and the role names in `roles`, its permissions in `permissions`
    # (permission?(key) understands "*"); a single-role app gets roles [role] and permissions [].
    Result = Data.define(:sub, :active, :role, :email, :name, :sessions_valid_after, :checked_at, :fetched_at, :stale,
                         :roles, :permissions) do
      include Permissions

      def initialize(roles: nil, permissions: nil, **fields)
        super(**fields, roles: Permissions.role_list(roles, fields[:role]), permissions: Permissions.list(permissions))
      end

      def active? = active == true
      def stale? = stale == true

      # Did the user sign out everywhere (or get signed out) after this session started?
      def session_revoked?(session_started_at)
        !sessions_valid_after.nil? && !session_started_at.nil? && session_started_at.to_i < sessions_valid_after.to_i
      end
    end

    # One member of the app (GET /api/v1/access); roles/permissions as in Result.
    Member = Data.define(:sub, :role, :email, :name, :sessions_valid_after, :roles, :permissions) do
      include Permissions

      def initialize(roles: nil, permissions: nil, **fields)
        super(**fields, roles: Permissions.role_list(roles, fields[:role]), permissions: Permissions.list(permissions))
      end
    end

    # The members list. not_modified? true (with members nil) when the ETag still matched.
    Members = Data.define(:members, :etag, :not_modified) do
      def not_modified? = not_modified == true
    end

    module_function

    # The user's access, cached for the API's max-age (at most LOGIN_ACCESS_CACHE_SECONDS). When the
    # auth app cannot be reached, the last known answer is returned (stale) while it is younger than the
    # grace period (LOGIN_GRACE_HOURS); otherwise TourpaqAuth::Unavailable is raised. A refusal that is not
    # an outage (wrong client secret, …) raises TourpaqAuth::Error. force: true skips the fresh cache.
    def check(sub, force: false)
      sub = sub.to_s
      raise ArgumentError, "sub is blank" if sub.strip.empty?
      config = TourpaqAuth.config
      key = cache_key(sub)
      entry = read(key)
      now = TourpaqAuth.now.to_i
      return from_entry(entry) if entry && !force && now < entry["fresh_until"].to_i

      begin
        status, body, headers = Api.call(:get, "/api/v1/access/#{URI.encode_www_form_component(sub)}")
        Api.refused!(status, body) unless status == 200
        json = Http.parse_json(body)
        raise Error, "The access answer is not an object" unless json.is_a?(Hash)
      rescue Unavailable => e
        if entry && now - entry["fetched_at"].to_i < config.grace_seconds
          TourpaqAuth.log(:warn, "access check for #{sub}: #{e.message}; using the answer from #{Time.at(entry['fetched_at'].to_i).utc.iso8601}")
          return from_entry(entry, stale: true)
        end
        raise
      end

      ttl = [ config.access_cache_seconds, Http.max_age(headers) ].compact.min
      active = json["active"] == true
      entry = { "sub" => json["sub"] || sub, "active" => active, "role" => active ? json["role"] : nil,
                "roles" => active && json.key?("roles") ? Array(json["roles"]) : nil,
                "permissions" => active ? Array(json["permissions"]) : [],
                "email" => json["email"], "name" => json["name"], "sessions_valid_after" => json["sessions_valid_after"],
                "checked_at" => json["checked_at"], "fetched_at" => now, "fresh_until" => now + ttl }
      # Kept for the grace period, so it can stand in during an outage.
      config.cache.write(key, entry, expires_in: [ ttl, config.grace_seconds ].max)
      from_entry(entry)
    end

    # Forgets the cached answer for one user (e.g. right after a login).
    def forget(sub) = TourpaqAuth.config.cache.delete(cache_key(sub.to_s))

    # GET /api/v1/access: everybody with access to this app. Pass the previous ETag to get
    # not_modified? back when nothing changed. Raises Unavailable or Error.
    def members(etag: nil)
      headers = etag.to_s.empty? ? {} : { "If-None-Match" => etag }
      status, body, response_headers = Api.call(:get, "/api/v1/access", headers: headers)
      return Members.new(members: nil, etag: etag, not_modified: true) if status == 304
      Api.refused!(status, body) unless status == 200

      json = Http.parse_json(body)
      list = json.is_a?(Array) ? json : (json.is_a?(Hash) && (json["members"] || json["users"]))
      raise Error, "The members answer has no list" unless list.is_a?(Array)
      members = list.map do |member|
        Member.new(sub: member["sub"], role: member["role"], email: member["email"], name: member["name"],
                   sessions_valid_after: IdToken.time_or_nil(member["sessions_valid_after"]),
                   roles: member.key?("roles") ? member["roles"] : nil, permissions: member["permissions"])
      end
      Members.new(members: members, etag: Http.header(response_headers, "ETag"), not_modified: false)
    end

    # For the app's members-sync job (SPECS.md §8.2): fetches the list with the last ETag (kept in the
    # cache) and yields the members only when it changed. The ETag is stored after the block returns, so
    # a failing sync is retried in full next time. Returns the Members.
    #
    #   TourpaqAuth::Access.sync_members { |members| User.sync_from_auth!(members) }
    def sync_members
      cache = TourpaqAuth.config.cache
      key = "tourpaq_auth:members_etag:#{TourpaqAuth.config.client_id}"
      result = members(etag: cache.read(key))
      return result if result.not_modified?
      yield result.members if block_given?
      result.etag ? cache.write(key, result.etag) : cache.delete(key)
      result
    end

    def cache_key(sub) = "tourpaq_auth:access:#{TourpaqAuth.config.client_id}:#{TourpaqAuth.digest(sub)}"

    def read(key)
      entry = TourpaqAuth.config.cache.read(key)
      entry.is_a?(Hash) ? entry.transform_keys(&:to_s) : nil
    end

    def from_entry(entry, stale: false)
      active = entry["active"] == true
      Result.new(sub: entry["sub"], active: active, role: entry["role"], email: entry["email"],
                 roles: active ? entry["roles"] : [], permissions: active ? entry["permissions"] : [],
                 name: entry["name"], sessions_valid_after: IdToken.time_or_nil(entry["sessions_valid_after"]),
                 checked_at: IdToken.time_or_nil(entry["checked_at"]) || Time.at(entry["fetched_at"].to_i).utc,
                 fetched_at: Time.at(entry["fetched_at"].to_i).utc, stale: stale)
    end
  end
end
