.PHONY: test

dev:
	watchexec -w src/ -e zig zig build run

test:
	watchexec -c -r  -w src/ -e zig zig build test

test-rss:
	watchexec -c -w src/ -e zig 'zig build test -- src/rss.zig'
