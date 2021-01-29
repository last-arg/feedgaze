.PHONY: test

dev:
	# watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_inbox delete lob'
	# watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_inbox add https://lobste.rs/'
	watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_inbox update'

test:
	watchexec -c -r  -w src/ -e zig zig build test

test-rss:
	watchexec -c -w src/ -e zig 'zig build test -- src/rss.zig'

test-http:
	watchexec -c -r -w src/ -e zig 'zig build test -- src/http.zig'

test-parse:
	watchexec -c -r -w src/ -e zig 'zig build test -- src/parse.zig'

db:
	./zig-cache/bin/feed_inbox add https://lobste.rs
	./zig-cache/bin/feed_inbox add https://dev.to/feed

