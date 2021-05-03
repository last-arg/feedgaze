default:
	echo 'Hello, world!'

test-active:
  watchexec -c -r -w src/ -e zig 'zig build test-active'

update:
  git submodule foreach git pull origin master
