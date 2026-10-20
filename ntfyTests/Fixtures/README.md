# Base64 message fixture

`base64-binary.json` is the unmodified HTTP response captured on 2026-10-20 from
stock ntfy v2.31.1, running on loopback with attachments disabled. Publish bytes
were `48 65 6c 6c 6f 20 66 72 6f 6d 20 6e 74 66 79 ff fe 00`.

```sh
ntfy serve --listen-http 127.0.0.1:18237 --base-url http://127.0.0.1:18237 \
  --cache-duration 1h --attachment-cache-dir ''
python3 -c 'import sys; sys.stdout.buffer.write(b"Hello from ntfy\xff\xfe\x00")' \
  | curl --data-binary @- 'http://127.0.0.1:18237/base64-regression?up=1'
```

`up=1` requests UnifiedPush's binary message path. Without it, this server rejects
the same binary body with HTTP 400 (`attachments not allowed`). The server only
emits base64 for non-UTF-8 bytes; valid UTF-8 decoding is covered by explicit wire
JSON tests because a normal UTF-8 publish has no encoding field.

Published macOS client binaries omit `serve`. To reproduce from source, check out
v2.31.1, run `make cli-deps-static-sites`, then
`go build -tags sqlite_omit_load_extension,osusergo,netgo -o ntfy .`.
