#!/bin/sh -e
if ! [ -d matrix-spec ]
then
git clone https://github.com/matrix-org/matrix-spec.git
(
cd matrix-spec
git checkout 31304300f5dc588f06a798cbda34b08b5800eb01
git apply ../scripts/parameter-order.patch
git apply ../scripts/put-room-keys-version.patch
git apply ../scripts/pusher-def.patch
git apply ../scripts/pusher-id.patch
git apply ../scripts/pusher-data-additional-properties.patch
git apply ../scripts/media-auth.patch
)
fi

(cd matrix-spec && python3 ./scripts/dump-swagger.py)
rm -f matrix.json
< matrix-spec/scripts/swagger/api-docs.json \
sed 's`](/`](https://spec.matrix.org/unstable/`g' |
jq '.paths |= with_entries(
  if .key | contains("/room_keys/") or contains("/keys/device_signing") then .key |= sub("/r0/";"/unstable/") else . end
)' \
> matrix.json
