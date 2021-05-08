default:
	echo 'Hello, world!'

run-local:
  zig build && ./zig-out/bin/feed_app add test/sample-rss-2.xml

watch-local:
  watchexec -c -r -w src/ -e zig 'zig build && ./zig-out/bin/feed_app add test/sample-rss-2.xml'

test file="" filter="":
  zig build test -- {{file}} {{filter}}

watch-test file="" filter="":
  watchexec -c -r -w src/ -e zig just test {{file}} {{filter}}

update:
  git submodule foreach git pull origin master
