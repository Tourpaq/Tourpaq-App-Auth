require "test_helper"
require "socket"

# The default seam (plain Net::HTTP) against a one-shot local server.
class HttpTest < TourpaqAuthTestCase
  def serve_once(response)
    server = TCPServer.new("127.0.0.1", 0)
    received = +""
    thread = Thread.new do
      client = server.accept
      while (line = client.gets) && line != "\r\n"
        received << line
      end
      length = received[/content-length: (\d+)/i, 1].to_i
      received << "\r\n" << client.read(length) if length.positive?
      client.write(response)
      client.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}", -> { thread.join(5) && received }
  ensure
    server&.close
  end

  def test_posts_forms_and_returns_status_body_and_headers
    body = '{"active":false}'
    serve_once("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: max-age=60\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}") do |base, received|
      status, response_body, headers = TourpaqAuth::Http.request(:post, "#{base}/oauth/introspect", form: { token: "abc" },
                                                                  headers: { "Authorization" => "Basic eDp5" })
      assert_equal 200, status
      assert_equal body, response_body
      assert_equal 60, TourpaqAuth::Http.max_age(headers)
      request = received.call
      assert_match %r{\APOST /oauth/introspect HTTP/1.1}, request
      assert_match(/^Authorization: Basic eDp5/i, request)
      assert_match(/^Accept: application\/json/i, request)
      assert request.end_with?("token=abc")
    end
  end

  def test_a_refused_connection_is_unavailable
    port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
    with_auth do
      TourpaqAuth.config.http = TourpaqAuth::Http.method(:request)
      TourpaqAuth.config.issuer = "http://127.0.0.1:#{port}"
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Access.check("someone") }
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Client.discovery }
      refute TourpaqAuth::Client.reachable?
    end
  end
end
