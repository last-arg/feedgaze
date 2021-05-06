default:
	echo 'Hello, world!'

watch-active:
  watchexec -c -r -w src/ -e zig 'zig build test-active'

update:
  git submodule foreach git pull origin master
