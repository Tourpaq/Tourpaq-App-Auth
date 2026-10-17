# A signed-in browser at one of the app's hosts (SPECS.md §3.3, §11.2, §24.1). Apps' own sessions are not
# here. The browser's cookie holds a random token; only its SHA-256 is stored.
#   kind "home"   the AUTH host's session (the Entra sign-in; the name is older than the auth host):
#                 SESSION_IDLE_HOURS idle (8), SESSION_MAX_DAYS (7) since the Entra sign-in
#   kind "index"  the INDEX host's session (signed in through the auth host as client "index"): the same
#                 limits, counted from the same Entra sign-in
#   kind "admin"  the ADMIN host's session: ADMIN_SESSION_IDLE_HOURS idle (2), ADMIN_REAUTH_HOURS (12)
#                 since the Entra sign-in
#
# entra_authenticated_at: the Entra sign-in behind the session (silent or not); the lifetime counts from it.
# entra_auth_time: when the person last gave Entra their credentials, from the auth_time claim of Entra's
# ID token (nil when Entra did not send it). Only it can satisfy prompt=login and max_age (SPECS.md §7.6).
#
#   session, plain = Session.start!(user:, kind: "home", ip_address:, user_agent:, entra_authenticated_at:, entra_auth_time:)
#   Session.find_by_plain(plain, kind: "home")   # an un-ended session of that kind, or nil
#   session.expired?  / session.end!("signed_out")
class Session < ApplicationRecord
  include HashedToken

  KINDS = %w[home index admin].freeze
  TOUCH_EVERY = 1.minute
  # Clock skew allowed between Entra's auth_time and our clock when a fresh sign-in was asked for.
  FRESH_SIGN_IN_LEEWAY = 5.minutes

  belongs_to :user
  has_many :authorization_codes, dependent: :nullify

  validates :kind, inclusion: { in: KINDS }
  validates :entra_authenticated_at, :last_seen_at, presence: true

  scope :active, -> { where(ended_at: nil) }
  scope :home, -> { where(kind: "home") }
  scope :index_host, -> { where(kind: "index") } # (a scope cannot be called "index")
  scope :admin, -> { where(kind: "admin") }
  scope :recent_first, -> { order(last_seen_at: :desc) }

  # Returns [session, plain token]; the plain token goes into the cookie only.
  def self.start!(user:, kind: "home", ip_address: nil, user_agent: nil, entra_authenticated_at: Time.current, entra_auth_time: nil)
    session = new(user: user, kind: kind, ip_address: ip_address, user_agent: user_agent&.truncate(255),
                  entra_authenticated_at: entra_authenticated_at, entra_auth_time: entra_auth_time, last_seen_at: Time.current)
    plain = session.assign_new_token
    session.save!
    [ session, plain ]
  end

  def self.find_by_plain(plain, kind:)
    return if plain.blank?
    active.where(kind: kind).includes(:user).find_by(token_digest: token_digest(plain))
  end

  def home? = kind == "home"
  def index? = kind == "index"
  def admin? = kind == "admin"
  def active? = ended_at.nil?

  # The host the session belongs to, for people: "auth" (the Entra sign-in), "index" or "admin".
  def host_label = home? ? "auth" : kind

  def idle_timeout
    admin? ? Rails.configuration.x.auth.admin_session_idle : Rails.configuration.x.auth.session_idle
  end

  def max_lifetime
    admin? ? Rails.configuration.x.auth.admin_reauth : Rails.configuration.x.auth.session_max
  end

  # Did the person give Entra their credentials at or after `time` (within FRESH_SIGN_IN_LEEWAY)? Never
  # when Entra did not say when (no auth_time claim).
  def credentials_given_since?(time)
    entra_auth_time.present? && entra_auth_time.to_i >= time.to_i - FRESH_SIGN_IN_LEEWAY.to_i
  end

  # The auth_time an app's ID token carries: Entra's, else the Entra sign-in behind the session.
  def auth_time = entra_auth_time || entra_authenticated_at

  def idle_expired? = last_seen_at < idle_timeout.ago
  def lifetime_expired? = entra_authenticated_at < max_lifetime.ago

  # Ended by a timeout, or started before the user's "sign out everywhere".
  def expired?
    idle_expired? || lifetime_expired? ||
      (user.sessions_valid_after.present? && created_at < user.sessions_valid_after)
  end

  def expiry_reason
    if idle_expired? then "idle"
    elsif lifetime_expired? then "expired"
    elsif expired? then "signed_out_everywhere"
    end
  end

  def end!(reason)
    update_columns(ended_at: Time.current, end_reason: reason.to_s, updated_at: Time.current) if active?
  end

  # Records activity at most once a minute, so ordinary page views do not write every time.
  def touch_seen!(ip_address: nil)
    return if last_seen_at > TOUCH_EVERY.ago
    update_columns(last_seen_at: Time.current, ip_address: ip_address || self.ip_address)
  end

  # "Firefox on macOS"-style label for the sessions list.
  def browser_label
    ua = user_agent.to_s
    browser = ua[/Edg\//] ? "Edge" : ua[/Firefox\//] ? "Firefox" : ua[/Chrome\//] ? "Chrome" : ua[/Safari\//] ? "Safari" : "Browser"
    os = ua[/iPhone|iPad/] ? "iOS" : ua[/Windows/] ? "Windows" : ua[/Android/] ? "Android" : ua[/Mac OS X|Macintosh/] ? "macOS" : ua[/Linux/] ? "Linux" : nil
    [ browser, os ].compact.join(" on ")
  end
end
