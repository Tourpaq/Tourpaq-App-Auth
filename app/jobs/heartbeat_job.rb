# Every 5 minutes (config/recurring.yml): tells the IRM that the auth app is alive (SPECS.md §15), by
# calling its heartbeat integration URL (IRM_HEARTBEAT_URL; GET, as the IRM's integrations.md shows).
# The heartbeat is only sent when the database answers, so "no heartbeat" in the IRM means "nobody
# can sign in". The URL holds the integration's secret: it is never logged.
class HeartbeatJob < ApplicationJob
  TIMEOUT = 10

  def perform
    url = Rails.configuration.x.auth.irm_heartbeat_url
    return if url.blank?
    ActiveRecord::Base.connection.select_value("SELECT 1")
    uri = URI(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.request(Net::HTTP::Get.new(uri))
    end
    Rails.logger.warn("[heartbeat] the IRM answered #{response.code}") unless response.is_a?(Net::HTTPSuccess)
  rescue StandardError => e
    Rails.logger.warn("[heartbeat] not sent: #{e.class}")
  end
end
