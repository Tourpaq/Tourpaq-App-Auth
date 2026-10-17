require "test_helper"
require "action_controller"
require "rack/mock"

class AccessCheckPagesController < ActionController::Base
  include TourpaqAuth::Rails::AccessCheck

  class << self
    attr_accessor :ended, :roles
  end

  skip_tourpaq_auth_access_check only: :login

  def show = render(plain: "ok")

  def login
    tourpaq_auth_signed_in(TourpaqAuth::Login.new(sub: params[:sub], email: nil, name: nil, role: params[:role],
                                                  sessions_valid_after: nil, authenticated_at: nil, claims: {}))
    render plain: "signed in"
  end

  private

  def tourpaq_auth_end_session(reason, result)
    self.class.ended << [ reason, result&.active? ]
    redirect_to "/login"
  end

  def tourpaq_auth_apply_role(role, result)
    self.class.roles << role
  end
end

class NoHookController < ActionController::Base
  include TourpaqAuth::Rails::AccessCheck
  def show = render(plain: "ok")
end

class RailsAccessCheckTest < TourpaqAuthTestCase
  def setup
    super
    @session = {}
    AccessCheckPagesController.ended = []
    AccessCheckPagesController.roles = []
  end

  def request(action, params = {}, controller: AccessCheckPagesController)
    env = Rack::MockRequest.env_for("/#{action}?#{URI.encode_www_form(params)}", "rack.session" => @session)
    status, headers, = controller.action(action).call(env)
    [ status, headers ]
  end

  def access_calls(provider) = provider.requests.count { _1[:path].start_with?("/api/v1/access/") }

  def sign_in(provider, role: "responder")
    sub = provider.add_user(email: "x@tourpaq.com", role: role)
    request(:login, { sub: sub, role: role })
    sub
  end

  def test_no_check_within_the_interval_after_login
    with_auth do |provider|
      sign_in(provider)
      travel 299
      assert_equal 200, request(:show).first
      assert_equal 0, access_calls(provider)
      assert_empty AccessCheckPagesController.ended
    end
  end

  def test_a_check_every_five_minutes
    with_auth do |provider|
      sign_in(provider)
      travel 301
      assert_equal 200, request(:show).first
      assert_equal 1, access_calls(provider)
      request(:show)
      assert_equal 1, access_calls(provider), "the next check is five minutes later"
      travel 301
      request(:show)
      assert_equal 2, access_calls(provider)
    end
  end

  def test_lost_access_ends_the_session
    with_auth do |provider|
      sub = sign_in(provider)
      provider.remove_access(sub)
      travel 301
      status, headers = request(:show)
      assert_equal 302, status
      assert_equal "http://example.org/login", headers["location"] || headers["Location"]
      assert_equal [ [ :no_access, false ] ], AccessCheckPagesController.ended
      assert_nil @session["tourpaq_auth"]
    end
  end

  def test_a_disabled_user_is_signed_out
    with_auth do |provider|
      sub = sign_in(provider)
      provider.disable_user(sub)
      travel 301
      assert_equal 302, request(:show).first
      assert_equal :no_access, AccessCheckPagesController.ended.last.first
    end
  end

  def test_sign_out_everywhere_ends_sessions_that_started_before_it
    with_auth do |provider|
      sub = sign_in(provider)
      travel 10
      provider.sign_out_everywhere(sub)
      travel 301
      assert_equal 302, request(:show).first
      assert_equal [ [ :signed_out_everywhere, true ] ], AccessCheckPagesController.ended

      # A session started after it is fine.
      request(:login, { sub: sub, role: "responder" })
      travel 301
      assert_equal 200, request(:show).first
    end
  end

  # The auth app rounds sessions_valid_after up (apps keep whole seconds), so a session that started in the same
  # second as the sign out ends too; the fake provider does the same.
  def test_a_sign_out_everywhere_in_the_same_second_as_the_sign_in_ends_the_session
    with_auth do |provider|
      TourpaqAuth.config.clock = -> { Time.at(Rational(1_791_900_026_200, 1000)) + @offset }
      sub = sign_in(provider)
      travel 0.3
      provider.sign_out_everywhere(sub)
      travel 301
      assert_equal 302, request(:show).first
      assert_equal [ [ :signed_out_everywhere, true ] ], AccessCheckPagesController.ended
    end
  end

  def test_a_changed_role_is_applied_once
    with_auth do |provider|
      sub = sign_in(provider, role: "viewer")
      provider.set_role(sub, "editor")
      travel 301
      assert_equal 200, request(:show).first
      assert_equal [ "editor" ], AccessCheckPagesController.roles
      travel 301
      request(:show)
      assert_equal [ "editor" ], AccessCheckPagesController.roles
      assert_equal "editor", @session["tourpaq_auth"]["role"]
    end
  end

  def test_an_outage_keeps_the_session_for_the_grace_period
    with_auth do |provider|
      sign_in(provider)
      travel 301
      request(:show) # confirmed by the auth app
      provider.reachable = false
      TourpaqAuth.config.cache.clear # e.g. the app restarted with a memory cache

      travel 12 * 3600
      assert_equal 200, request(:show).first
      calls = access_calls(provider)
      request(:show)
      assert_equal calls, access_calls(provider), "a failed check is not retried on every request"

      travel 12 * 3600
      assert_equal 302, request(:show).first
      assert_equal [ [ :unavailable, nil ] ], AccessCheckPagesController.ended
    end
  end

  # SPECS.md §13: only 5xx, 429 and network failures are an outage. A refusal (the app or its client
  # disabled in the auth app, its secret deleted) ends the session at the next check, with no grace period.
  def test_a_refused_check_ends_the_session_without_a_grace_period
    with_auth do |provider|
      sign_in(provider)
      travel 301
      assert_equal 200, request(:show).first # confirmed a moment ago
      provider.client_disabled = true

      travel 301
      status, headers = request(:show)
      assert_equal 302, status
      assert_equal "http://example.org/login", headers["location"] || headers["Location"]
      assert_equal [ [ :refused, nil ] ], AccessCheckPagesController.ended
      assert_nil @session["tourpaq_auth"]
    end
  end

  def test_a_refused_check_ends_a_session_that_never_was_confirmed
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com")
      # e.g. the IRM's PIN unlock: a start, no confirmation yet, so the first request checks.
      @session["tourpaq_auth"] = { "sub" => sub, "role" => "viewer", "started_at" => TourpaqAuth.now.to_i }
      provider.access_status = 403
      assert_equal 302, request(:show).first
      assert_equal [ [ :refused, nil ] ], AccessCheckPagesController.ended
    end
  end

  def test_a_server_error_is_still_an_outage
    with_auth do |provider|
      sign_in(provider)
      provider.access_status = 503
      travel 301
      assert_equal 200, request(:show).first
      assert_empty AccessCheckPagesController.ended
    end
  end

  def test_nobody_signed_in_means_nothing_to_check
    with_auth do |provider|
      assert_equal 200, request(:show).first
      assert_equal 0, access_calls(provider)
    end
  end

  def test_disabled_gem_checks_nothing
    with_auth(env: { "LOGIN_CLIENT_SECRET" => nil }) do |provider|
      @session["tourpaq_auth"] = { "sub" => "x", "checked_at" => 0 }
      assert_equal 200, request(:show).first
      assert_equal 0, access_calls(provider)
    end
  end

  def test_the_end_session_hook_is_required
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com")
      provider.remove_access(sub)
      @session["tourpaq_auth"] = { "sub" => sub, "started_at" => TourpaqAuth.now.to_i }
      assert_raises(NotImplementedError) { request(:show, controller: NoHookController) }
    end
  end
end
