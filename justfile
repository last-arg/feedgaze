default:
	echo 'Hello, world!'

test *args="":
  zig build test -- {{args}}

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
  ./test-server/redbean.com -d -D ./test/ -L tmp/redbean.log -p 8282 -P {{pid_path}} -r /rss2=/rss2.rss

test-server-shutdown:
  kill -TERM $(cat {{pid_path}})

test-db:
  -just test-server # make sure test server is running
  zig build
  ./zig-out/bin/feedgaze add --db tmp/test.db --tags a1,a2 http://localhost:8080/atom.atom
  ./zig-out/bin/feedgaze add --db tmp/test.db --tags r1,r2 test/rss2.xml

test-server-twitch:
  twitch mock-api start -p 8181
