require "test_helper"
require "open3"

# bin/docker-dev publishes the web port only for the server, judged by the command words: a one-off command whose
# arguments merely mention bin/dev-stack or "rails server" must not try to bind the port the running server holds.
# Runs the script with a stand-in `docker` on PATH that prints its `run` arguments.
class DockerDevTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/docker-dev").to_s

  setup do
    @bin = Dir.mktmpdir("fake-docker")
    File.write(File.join(@bin, "docker"), "#!/bin/sh\n[ \"$1\" = run ] && echo \"$@\"\nexit 0\n")
    File.chmod(0o755, File.join(@bin, "docker"))
  end

  teardown { FileUtils.rm_rf(@bin) }

  def run_args(*command)
    env = { "PATH" => "#{@bin}:#{ENV['PATH']}", "WEB_PORT" => nil, "DOCKER_NAME" => nil, "ENV_FILE" => nil }
    out, err, status = Open3.capture3(env, "bash", SCRIPT, *command, stdin_data: "")
    assert status.success?, err
    out
  end

  def publishes?(*command) = run_args(*command).include?("-p 3050:3050")

  test "the server publishes the port" do
    assert publishes?, "no arguments: the server"
    assert publishes?("bin/dev")
    assert publishes?("bin/rails", "server", "-b", "0.0.0.0")
    assert publishes?("bin/rails", "s")
    assert publishes?("bundle", "exec", "rails", "server")
  end

  test "a one-off command does not, whatever its arguments mention" do
    assert_not publishes?("bin/rails", "test")
    assert_not publishes?("bin/rails", "runner", "puts 'see bin/dev-stack'")
    assert_not publishes?("bin/rails", "runner", "puts 'bin/rails server'")
    assert_not publishes?("bash", "-c", "bin/dev-stack status")
    assert_not publishes?("bin/dev-stack")
  end

  test "WEB_PORT moves the published port" do
    env = { "PATH" => "#{@bin}:#{ENV['PATH']}", "WEB_PORT" => "3051", "ENV_FILE" => nil, "DOCKER_NAME" => nil }
    out, = Open3.capture3(env, "bash", SCRIPT, stdin_data: "")
    assert_includes out, "-p 3051:3050"
  end
end
