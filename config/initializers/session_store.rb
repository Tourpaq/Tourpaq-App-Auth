# Rails' own cookie session (OmniAuth state/nonce/PKCE verifier, return-to, flash). Host-only (no
# domain), so the home and admin hosts each have their own and no other *.app.journeybooking.eu app
# can read or set it (SPECS.md §14). The sign-in sessions themselves are server-side rows
# (Session, app/models/session.rb) in their own host-only cookies.
Rails.application.config.session_store :cookie_store, key: "_tourpaq_auth", same_site: :lax, httponly: true
