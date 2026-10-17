# An OAuth/OIDC client of an app (SPECS.md §7.4).
#   web        confidential: client secrets (at most two active), may call the authorization API
#   extension  public: PKCE required, no secret, refresh tokens (§10)
#   internal   the hosts' own clients (§11.2, §24.1), no app and no secret (the host is this same process, so
#              its code exchange happens in-process): "admin" (access = active admin, redirect URI from
#              ADMIN_URL) and "index" (access = active user, redirect URI from INDEX_URL)
#
#   plain = client.generate_secret!(expires_at: 1.year.from_now)  # shown once
#   client.authenticate_secret(plain)                              # the ClientSecret, or nil
#   client.redirect_uri_allowed?(uri)                              # exact match, no wildcards
class Client < ApplicationRecord
  KINDS = %w[web extension internal].freeze
  ADMIN_CLIENT_ID = "admin".freeze
  INDEX_CLIENT_ID = "index".freeze
  INTERNAL_CLIENTS = { ADMIN_CLIENT_ID => "Admin host", INDEX_CLIENT_ID => "Index host" }.freeze
  MAX_ACTIVE_SECRETS = 2
  SECRET_PREFIX = "tpcs_".freeze

  class TooManySecrets < StandardError; end

  belongs_to :app, optional: true
  has_many :client_secrets, dependent: :destroy
  has_many :authorization_codes, dependent: :delete_all
  has_many :oauth_tokens, dependent: :destroy
  has_many :usage_counts, dependent: :delete_all

  normalizes :client_id, with: ->(id) { id.to_s.strip.downcase }
  attr_readonly :client_id

  validates :client_id, presence: true, uniqueness: true, format: { with: /\A[a-z0-9]+(-[a-z0-9]+)*\z/ }
  validates :kind, inclusion: { in: KINDS }
  validates :app, presence: true, unless: :internal?
  validate :redirect_uris_are_exact
  validate :post_logout_only_for_web

  scope :ordered, -> { order(:client_id) }
  scope :active, -> { where(disabled_at: nil) }

  # The admin host's client (§11.2) and the index host's (§24.1), created on first use.
  def self.admin_client = internal_client(ADMIN_CLIENT_ID)
  def self.index_client = internal_client(INDEX_CLIENT_ID)

  def self.internal_client(client_id)
    name = INTERNAL_CLIENTS.fetch(client_id)
    find_or_create_by!(client_id: client_id) do |client|
      client.kind = "internal"
      client.name = name
    end
  end

  def self.find_active(client_id) = active.includes(:app).find_by(client_id: client_id.to_s)

  def web? = kind == "web"
  def extension? = kind == "extension"
  def internal? = kind == "internal"
  def confidential? = web?
  def public_client? = extension?
  def requires_pkce? = extension?
  def may_call_api? = web?
  def active? = disabled_at.nil? && (internal? || app&.active?)

  # --- Redirect URIs (§7.4, §14: exact match, no wildcards) ------------------------------------

  def admin_client? = internal? && client_id == ADMIN_CLIENT_ID
  def index_client? = internal? && client_id == INDEX_CLIENT_ID

  # An internal client's URIs follow its host's URL (ADMIN_URL, INDEX_URL); nothing is stored for them.
  def redirect_uris
    return Array(self[:redirect_uris]) unless internal?
    index_client? ? [ AuthHosts.index_callback_url ] : admin_client? ? [ AuthHosts.admin_callback_url ] : []
  end

  def post_logout_redirect_uris
    return Array(self[:post_logout_redirect_uris]) unless internal?
    index_client? ? [ "#{AuthHosts.index_url}/signed_out" ] : admin_client? ? [ "#{AuthHosts.admin_url}/" ] : []
  end

  def redirect_uri_allowed?(uri) = uri.present? && redirect_uris.include?(uri.to_s)
  def post_logout_redirect_uri_allowed?(uri) = uri.present? && post_logout_redirect_uris.include?(uri.to_s)

  # Accepts a newline/comma separated string from a form as well as an array.
  def redirect_uris=(value)
    super(self.class.uri_list(value))
  end

  def post_logout_redirect_uris=(value)
    super(self.class.uri_list(value))
  end

  def self.uri_list(value)
    (value.is_a?(String) ? value.split(/[\s,]+/) : Array(value)).map { _1.to_s.strip }.reject(&:blank?).uniq
  end

  # https anywhere, or http on localhost / 127.0.0.1 (development of the apps). No fragment, no
  # wildcard, no userinfo.
  def self.acceptable_uri?(uri)
    parsed = URI.parse(uri)
    return false if parsed.host.blank? || parsed.fragment || parsed.userinfo || uri.include?("*")
    parsed.scheme == "https" || (parsed.scheme == "http" && %w[localhost 127.0.0.1 [::1]].include?(parsed.host))
  rescue URI::InvalidURIError
    false
  end

  # --- Secrets (web clients, §7.4) ---------------------------------------------------------------

  def active_secrets = client_secrets.active.order(:created_at)

  # Creates a secret and returns the plain value (shown once). At most two active at a time:
  # create the new one, deploy the app with it, then delete the old one.
  def generate_secret!(expires_at: nil, created_by: Current.user)
    raise ArgumentError, "only web clients have secrets" unless web?
    transaction do
      lock!
      raise TooManySecrets, "#{client_id} already has #{MAX_ACTIVE_SECRETS} active secrets: delete one first" if active_secrets.count >= MAX_ACTIVE_SECRETS
      secret = client_secrets.build(expires_at: expires_at, created_by: created_by)
      plain = secret.assign_new_token(prefix: SECRET_PREFIX)
      secret.save!
      AuditEvent.record("client.secret_created", subject: self, actor: created_by, data: { hint: secret.hint, expires_at: expires_at&.utc&.iso8601 }.compact)
      plain
    end
  end

  # The matching active ClientSecret, or nil. Compares against every active secret in constant
  # time (no early exit), and records its use at most once a minute.
  def authenticate_secret(plain)
    return nil unless web? && active? && plain.present?
    digest = HashedToken.digest(plain)
    match = nil
    active_secrets.each { |secret| match = secret if ActiveSupport::SecurityUtils.secure_compare(secret.secret_digest, digest) }
    match&.touch_used!
    match
  end

  # Finds the client by id and checks the secret: nil unless both match an active web client.
  def self.authenticate(client_id, plain)
    client = find_active(client_id)
    client if client&.authenticate_secret(plain)
  end

  def to_s = client_id

  private

  def redirect_uris_are_exact
    return if internal?
    (Array(self[:redirect_uris]) + Array(self[:post_logout_redirect_uris])).each do |uri|
      errors.add(:redirect_uris, "#{uri} is not allowed: https only (http for localhost), no wildcards or fragments") unless self.class.acceptable_uri?(uri)
    end
  end

  def post_logout_only_for_web
    errors.add(:post_logout_redirect_uris, "are only for web clients") if extension? && Array(self[:post_logout_redirect_uris]).any?
  end
end
