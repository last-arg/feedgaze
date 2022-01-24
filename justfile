default:
	echo 'Hello, world!'

run-local:
  zig build && ./zig-out/bin/feedgaze add test/sample-rss-2.xml

watch-local:
  watchexec -c -r -w src/ -e zig just run-local

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
test-server:
  ./test-server/redbean.com -dD ./test/ 
