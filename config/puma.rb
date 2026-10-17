# Puma configuration (https://puma.io/puma/Puma/DSL.html). One process, a few threads.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests.
port ENV.fetch("PORT", 3050)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Solid Queue runs inside Puma (SPECS.md §19): one container, no separate worker.
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"].present? && ENV["SOLID_QUEUE_IN_PUMA"] != "false"

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
