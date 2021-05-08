default:
	echo 'Hello, world!'

run-local:
  zig build && ./zig-out/bin/feed_app add test/sample-rss-2.xml

watch-local:
  watchexec -c -r -w src/ -e zig 'zig build && ./zig-out/bin/feed_app add test/sample-rss-2.xml'

watch-active:
  watchexec -c -r -w src/ -e zig 'zig build test-active'

test-cli:
  zig build test -- src/cli.zig

watch-active-cli:
  watchexec -c -r -w src/ -e zig 'zig build test-active -- src/cli.zig'

watch-active-shame:
  watchexec -c -r -w src/ -e zig 'zig build test-active -- src/shame.zig'

watch-active-feeddb:
  watchexec -c -r -w src/ -e zig 'zig build test-active -- src/feed_db.zig'

build-run:
  zig build run

update:
  git submodule foreach git pull origin master
