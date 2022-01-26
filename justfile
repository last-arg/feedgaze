default:
	echo 'Hello, world!'

test file="" filter="":
  zig build test -- {{file}} {{filter}}

watch-test file="" filter="":
  watchexec -c -r -w src/ -e zig just test {{file}} {{filter}}

watch-cli args="":
	watchexec -c -r -w src/ -e zig 'zig build run -- {{args}}'

watch-build:
  watchexec -c -r -w src/ -e zig 'zig build'

# Ctrl+c doesn't work with just test-server when run in foreground
# Start a test server in background
pid_path := "tmp/redbean.pid"
test-server:
  ./test-server/redbean.com -dD ./test/ -L tmp/redbean.log -P {{pid_path}}

test-server-shutdown:
  kill -TERM $(cat {{pid_path}})
