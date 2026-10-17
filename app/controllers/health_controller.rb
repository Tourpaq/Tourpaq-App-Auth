# GET /up/ready (SPECS.md §15): the database answers. GET /up (Rails::HealthController) is process
# liveness only, with no database query; Coolify's health check uses /up.
class HealthController < ActionController::API
  def ready
    ActiveRecord::Base.connection.select_value("SELECT 1")
    render json: { status: "ok", database: "ok" }
  rescue StandardError => e
    render json: { status: "error", database: e.class.name }, status: :service_unavailable
  end
end
