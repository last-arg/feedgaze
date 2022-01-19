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

watch-update:
	watchexec -c -r -w src/ -e zig 'zig build && ./zig-out/bin/feedgaze update --force'

watch-search:
	watchexec -c -r -w src/ -e zig 'zig build && ./zig-out/bin/feedgaze search dev'

watch-build:
    watchexec -c -r -w src/ -e zig 'zig build'

update:
  git submodule foreach git pull origin master
