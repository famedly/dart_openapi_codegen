#!/bin/sh -e
if ! [ -d matrix-doc ]
then
git clone https://github.com/matrix-org/matrix-doc.git
(
cd matrix-doc
git remote add fork https://github.com/lukaslihotzki/matrix-doc.git
git fetch fork
git merge --no-edit fork/parameter-order
git merge --no-edit fork/fix-putRoomKeysVersion
git merge --no-edit fork/include-peek-events
)
fi

(cd matrix-doc && ./scripts/dump-swagger.py -c r0)
rm -f matrix.json
< matrix-doc/scripts/swagger/api-docs.json \
sed 's`](/`](https://spec.matrix.org/unstable/`g' |
jq '.paths |= with_entries(
  if .key | contains("/room_keys/") or contains("/keys/device_signing") then .key |= sub("/r0/";"/unstable/") else . end
)' \
> matrix.json
