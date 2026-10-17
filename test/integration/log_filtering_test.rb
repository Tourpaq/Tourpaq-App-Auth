require "test_helper"

# Nothing secret reaches the log (SPECS.md §14, §22).
class LogFilteringTest < ActionDispatch::IntegrationTest
  test "authorization codes, tokens, secrets and session tokens are filtered" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    previous = Rails.logger
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
    begin
      sign_in_as users(:alice)
      session_plain = cookies[:home_session].to_s
      get "/", params: { code: "entra-code-xyz", token: "tpa_irm_secretvalue", client_secret: "tpcs_secretvalue",
                         refresh_token: "tpr_irm_refresh", password: "hunter2" }
      PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "x")
      clients(:irm_web).generate_secret!
    ensure
      Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = previous
    end

    log = output.string
    assert_match "[FILTERED]", log
    %w[entra-code-xyz tpa_irm_secretvalue tpcs_secretvalue tpr_irm_refresh hunter2].each { assert_no_match(/#{_1}/, log) }
    assert_no_match(/#{Regexp.escape(session_plain)}/, log) if session_plain.present?
    assert_no_match(/tpa_irm_[A-Za-z0-9_-]{43}/, log)
    assert_no_match(/tpcs_[A-Za-z0-9_-]{43}/, log)
  end
end
