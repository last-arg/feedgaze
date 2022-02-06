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
  ./test-server/redbean.com -d -D ./test/ -L tmp/redbean.log -P {{pid_path}}

test-server-shutdown:
  kill -TERM $(cat {{pid_path}})

test-db:
  -just test-server # make sure test server is running
  zig build run -- add --db tmp/test.db --tags t1,t2 http://localhost:8080/atom.atom test/rss2.xml
