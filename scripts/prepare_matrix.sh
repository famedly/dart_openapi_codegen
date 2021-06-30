#!/bin/sh -e
[ -d matrix-doc ] || git clone https://github.com/matrix-org/matrix-doc.git
(cd matrix-doc && ./scripts/dump-swagger.py -c r0)
rm matrix.json
< matrix-doc/scripts/swagger/api-docs.json \
sed 's`](/`](https://spec.matrix.org/unstable/`g' |
jq '.paths |= with_entries(
  if .key | contains("/room_keys/") then .key |= sub("/r0/";"/unstable/") else . end
)' \
> matrix.json
