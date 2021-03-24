.PHONY: test

dev:
	# watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_app delete lob'
	# watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_app add https://lobste.rs/'
	watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_app add https://lobste.rs'

test-local:
	watchexec -c -r  -w src/ -e zig 'zig build && ./zig-cache/bin/feed_app add test/sample-rss-091.xml'

test:
	watchexec -c -r  -w src/ -e zig zig build test

test-db:
	watchexec -c -w src/ -e zig 'zig build test -- src/db.zig'

test-http:
	watchexec -c -r -w src/ -e zig 'zig build test -- src/http.zig'

test-parse:
	watchexec -c -r -w src/ -e zig 'zig build test -- src/parse.zig'

run-print:
	watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_app print'

run-delete:
	watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_app delete write'

run-update:
	watchexec -c -r -w src/ -e zig 'zig build && ./zig-cache/bin/feed_app update --force'

db:
	./zig-cache/bin/feed_app add https://lobste.rs
	./zig-cache/bin/feed_app add https://dev.to/feed

