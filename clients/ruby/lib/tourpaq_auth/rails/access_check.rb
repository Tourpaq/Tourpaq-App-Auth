require "active_support/concern"

module TourpaqAuth
  module Rails
    # Re-checks a signed-in user's access with the auth app (SPECS.md §8.3), at most every
    # LOGIN_ACCESS_CACHE_SECONDS (5 minutes) per browser session:
    #
    # - access gone (disabled, removed, unknown)         → tourpaq_auth_end_session(:no_access, result)
    # - session started before sessions_valid_after      → tourpaq_auth_end_session(:signed_out_everywhere, result)
    # - a different role                                 → tourpaq_auth_apply_role(role, result)
    # - different roles or permissions (a permission app,
    #   SPECS.md §23.2; also after a single role changed) → tourpaq_auth_apply_permissions(roles, permissions, result)
    # - auth app unreachable and the last confirmation is
    #   older than the grace period (LOGIN_GRACE_HOURS)  → tourpaq_auth_end_session(:unavailable, nil)
    # - auth app refuses the check (401 invalid_client:
    #   the app or its client disabled, the secret
    #   deleted; 403, 400, a malformed answer)           → tourpaq_auth_end_session(:refused, nil)
    #
    # Only an outage (network failure, timeout, 5xx, 429: TourpaqAuth::Unavailable) is bridged by the grace
    # period (SPECS.md §13). A refusal is the auth app saying no, so the session ends at once.
    #
    # Use:
    #
    #   class ApplicationController < ActionController::Base
    #     include TourpaqAuth::Rails::AccessCheck
    #
    #     # after a login through the auth app:
    #     #   tourpaq_auth_signed_in(login)              (login: a TourpaqAuth::Login)
    #
    #     private
    #
    #     def tourpaq_auth_end_session(reason, result)  # required
    #       terminate_session
    #       redirect_to login_path, alert: "Your access has changed. Sign in again."
    #     end
    #
    #     def tourpaq_auth_apply_role(role, result)     # optional
    #       Current.user.update!(role: role)
    #     end
    #
    #     def tourpaq_auth_apply_permissions(roles, permissions, result)   # optional (permission apps)
    #       session[:permissions] = permissions
    #     end
    #   end
    #
    # The concern keeps its state in the Rails session under "tourpaq_auth" (sub, role, a short digest of the
    # roles and permissions, when the session started, when it last checked, when the auth app last confirmed).
    # The permissions themselves are not kept there (a cookie session is small): keep them where the app keeps
    # its session data, from tourpaq_auth_apply_permissions and the login. Apps that know these better can
    # override tourpaq_auth_subject, tourpaq_auth_current_role and tourpaq_auth_session_started_at.
    module AccessCheck
      extend ActiveSupport::Concern

      SESSION_KEY = "tourpaq_auth".freeze
      REASONS = %i[no_access signed_out_everywhere unavailable refused].freeze

      included do
        before_action :tourpaq_auth_check_access
      end

      class_methods do
        def skip_tourpaq_auth_access_check(**options)
          skip_before_action :tourpaq_auth_check_access, **options
        end
      end

      private

      # Call right after signing someone in through the auth app. `login` is a TourpaqAuth::Login (or
      # anything with sub and role). The ID token's role is the role at login (SPECS.md §8.3).
      def tourpaq_auth_signed_in(login, started_at: TourpaqAuth.now)
        now = TourpaqAuth.now.to_i
        roles = login.respond_to?(:roles) ? login.roles : [ login.role ].compact
        permissions = login.respond_to?(:permissions) ? login.permissions : []
        session[SESSION_KEY] = { "sub" => login.sub, "role" => login.role, "access" => tourpaq_auth_access_digest(roles, permissions),
                                 "started_at" => started_at.to_i, "checked_at" => now, "confirmed_at" => now }
      end

      def tourpaq_auth_signed_out
        session.delete(SESSION_KEY)
      end

      # --- hooks -------------------------------------------------------------------------------------

      # The signed-in user's subject, or nil when nobody is signed in (then nothing is checked).
      def tourpaq_auth_subject = tourpaq_auth_state["sub"]

      # The role the app currently gives the user.
      def tourpaq_auth_current_role = tourpaq_auth_state["role"]

      # When this app session started (a Time), or nil to skip the sessions_valid_after check.
      def tourpaq_auth_session_started_at
        started = tourpaq_auth_state["started_at"]
        started ? Time.at(started.to_i).utc : nil
      end

      # Ends the app's session; render or redirect here. Required.
      def tourpaq_auth_end_session(reason, result)
        raise NotImplementedError, "#{self.class.name} includes TourpaqAuth::Rails::AccessCheck: define tourpaq_auth_end_session(reason, result)"
      end

      # Applies a changed role (nil never reaches here: no role means no access). Optional.
      def tourpaq_auth_apply_role(role, result) = nil

      # Applies changed roles or permissions (SPECS.md §23.2: a permission app reads its permissions from the
      # auth app). Called when either differs from what the session last saw. Optional.
      def tourpaq_auth_apply_permissions(roles, permissions, result) = nil

      # --- the check ---------------------------------------------------------------------------------

      def tourpaq_auth_check_access
        return unless TourpaqAuth.enabled?
        sub = tourpaq_auth_subject
        return if sub.nil? || sub.to_s.empty?

        state = tourpaq_auth_state
        state = { "sub" => sub.to_s } unless state["sub"] == sub.to_s
        now = TourpaqAuth.now.to_i
        config = TourpaqAuth.config
        return if state["checked_at"] && now - state["checked_at"].to_i < config.access_cache_seconds

        begin
          result = TourpaqAuth::Access.check(sub)
        rescue TourpaqAuth::Unavailable => e
          confirmed = state["confirmed_at"] || state["started_at"]
          if confirmed && now - confirmed.to_i < config.grace_seconds
            TourpaqAuth.log(:warn, "access check for #{sub} failed (#{e.message}); within the grace period")
            state["checked_at"] = now
            session[SESSION_KEY] = state
          else
            TourpaqAuth.log(:warn, "access check for #{sub} failed (#{e.message}); grace period over, ending the session")
            tourpaq_auth_end!(:unavailable, nil)
          end
          return
        rescue TourpaqAuth::Error => e
          # Not an outage: the auth app refused (e.g. this app or its client is disabled there, or the
          # secret was deleted). No grace period: the session ends.
          TourpaqAuth.log(:error, "access check for #{sub} refused (#{e.message}); ending the session")
          tourpaq_auth_end!(:refused, nil)
          return
        end

        state["checked_at"] = now
        state["confirmed_at"] = result.fetched_at.to_i unless result.stale?
        session[SESSION_KEY] = state

        if !result.active?
          tourpaq_auth_end!(:no_access, result)
        elsif result.session_revoked?(tourpaq_auth_session_started_at)
          tourpaq_auth_end!(:signed_out_everywhere, result)
        else
          if result.role != tourpaq_auth_current_role
            tourpaq_auth_apply_role(result.role, result)
            state["role"] = result.role
            session[SESSION_KEY] = state
          end
          digest = tourpaq_auth_access_digest(result.roles, result.permissions)
          if digest != state["access"]
            tourpaq_auth_apply_permissions(result.roles, result.permissions, result)
            state["access"] = digest
            session[SESSION_KEY] = state
          end
        end
      end

      def tourpaq_auth_access_digest(roles, permissions)
        TourpaqAuth.digest(JSON.generate([ Array(roles).map(&:to_s).sort, Array(permissions).map(&:to_s).sort ]))[0, 16]
      end

      def tourpaq_auth_end!(reason, result)
        session.delete(SESSION_KEY)
        tourpaq_auth_end_session(reason, result)
      end

      def tourpaq_auth_state
        state = session[SESSION_KEY]
        state.is_a?(Hash) ? state.transform_keys(&:to_s) : {}
      end
    end
  end
end
