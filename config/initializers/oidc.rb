# The OIDC provider's signing key (SPECS.md §7.3, §14; Oidc::SigningKeys). Production refuses to start
# without a usable OIDC_SIGNING_KEY (RSA, 2048 bits or more, PEM), rather than failing at the first
# sign-in. The asset build (SECRET_KEY_BASE_DUMMY) has no keys and is not checked.
Rails.application.config.after_initialize do
  if Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
    Oidc::SigningKeys.current
    Oidc::SigningKeys.previous
  end
end
