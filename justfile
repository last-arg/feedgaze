default:
	echo 'Hello, world!'

run-local:
  zig build && ./zig-out/bin/feed_app add test/sample-rss-2.xml

watch-local:
  watchexec -c -r -w src/ -e zig 'zig build && ./zig-out/bin/feed_app add test/sample-rss-2.xml'

watch-active:
  watchexec -c -r -w src/ -e zig 'zig build test-active'

update:
  git submodule foreach git pull origin master
