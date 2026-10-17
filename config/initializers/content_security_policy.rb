# Strict Content Security Policy: only our own scripts and styles, plus the per-request nonce on the
# importmap tags and Turbo's progress bar style (Turbo reads the nonce from the csp-nonce meta tag).
# Views must not use inline style attributes, inline <script> or inline event handlers.
Rails.application.configure do
  origin = ->(url) { uri = URI(url); "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless [ 80, 443 ].include?(uri.port)}" }
  auth = config.x.auth

  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self
    policy.img_src     :self, :data
    policy.font_src    :self
    policy.connect_src :self
    policy.object_src  :none
    policy.base_uri    :self
    # Browsers apply form-action to the redirects after a form post: the Entra sign-in start (POST
    # /auth/entra_id) redirects to Microsoft, and the index host's sign out goes through the auth host's
    # /oauth/logout and back to the index host.
    policy.form_action :self, origin.(auth.app_url), origin.(auth.index_url), origin.(auth.admin_url), "https://login.microsoftonline.com"
    policy.frame_ancestors :none
  end

  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s.presence || SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
end
