#!/bin/sh -e
if ! [ -d matrix-doc ]
then
git clone https://github.com/matrix-org/matrix-doc.git
(
cd matrix-doc
git checkout 8b2c12626094d16457b35b5af4a5ed6e1ac5b4c2
git apply ../scripts/parameter-order.patch
git apply ../scripts/put-room-keys-version.patch
git apply ../scripts/pusher-data-additional-properties.patch
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
