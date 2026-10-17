require "test_helper"
require "action_controller"
require "rack/mock"

class BearerApiController < ActionController::API
  include TourpaqAuth::Rails::BearerToken

  require_tourpaq_auth_token
  require_tourpaq_auth_token write: true, only: :create

  def index = render(json: { sub: tourpaq_auth_token.sub, scope: tourpaq_auth_token.scope, role: tourpaq_auth_token.role })
  def create = render(json: { ok: true }, status: :created)
end

class RailsBearerTokenTest < TourpaqAuthTestCase
  def call(action, authorization = nil)
    env = Rack::MockRequest.env_for("/#{action}", method: action == :create ? "POST" : "GET")
    env["HTTP_AUTHORIZATION"] = authorization if authorization
    status, headers, body = BearerApiController.action(action).call(env)
    text = +""
    body.each { text << _1 }
    [ status, headers.transform_keys(&:downcase), text.empty? ? {} : JSON.parse(text) ]
  end

  def test_a_valid_token_exposes_the_introspection_result
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com", role: "responder")
      token = provider.issue_token(sub: sub, scope: "read")
      status, _, body = call(:index, "Bearer #{token}")
      assert_equal 200, status
      assert_equal({ "sub" => sub, "scope" => "read", "role" => "responder" }, body)
    end
  end

  def test_no_token_is_401_with_a_challenge
    with_auth do |provider|
      status, headers, body = call(:index)
      assert_equal 401, status
      assert_equal "Bearer", headers["www-authenticate"]
      assert_equal "unauthorized", body["error"]
      status, = call(:index, "Basic #{['a:b'].pack('m0')}")
      assert_equal 401, status
      assert_equal 0, provider.introspections
    end
  end

  def test_an_invalid_token_is_401_invalid_token
    with_auth do
      status, headers, body = call(:index, "Bearer tpa_test_nope")
      assert_equal 401, status
      assert_equal %(Bearer error="invalid_token"), headers["www-authenticate"]
      assert_equal "invalid_token", body["error"]
    end
  end

  def test_writing_needs_read_write
    with_auth do |provider|
      sub = provider.add_user(email: "x@tourpaq.com")
      status, _, body = call(:create, "Bearer #{provider.issue_token(sub: sub, scope: 'read')}")
      assert_equal 403, status
      assert_equal "insufficient_scope", body["error"]
      assert_equal 201, call(:create, "Bearer #{provider.issue_token(sub: sub, scope: 'read_write')}").first
    end
  end

  def test_introspected_once_per_request
    with_auth do |provider|
      token = provider.issue_token(sub: provider.add_user(email: "x@tourpaq.com"), scope: "read_write")
      call(:create, "Bearer #{token}")
      assert_equal 1, provider.introspections(token)
    end
  end

  def test_an_outage_is_503
    with_auth do |provider|
      provider.reachable = false
      status, headers, body = call(:index, "Bearer tpa_test_x")
      assert_equal 503, status
      assert_equal "30", headers["retry-after"]
      assert_equal "temporarily_unavailable", body["error"]
    end
  end

  def test_not_configured_refuses_tokens
    with_auth(env: { "LOGIN_ISSUER" => nil }) do
      assert_equal 401, call(:index, "Bearer tpa_test_x").first
    end
  end
end
