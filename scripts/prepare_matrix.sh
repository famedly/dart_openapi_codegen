#!/bin/sh -e
if ! [ -d matrix-spec ]
then
git clone https://github.com/matrix-org/matrix-spec.git --branch v1.19 --single-branch
(
cd matrix-spec
echo "Applying media upload format patch"
git apply ../scripts/media-upload-format.patch

echo "Applying put room keys version patch"
git apply ../scripts/put-room-keys-version.patch

echo "Applying pusher definition patch"
git apply ../scripts/pusher-def.patch

echo "Applying pusher ID patch"
git apply ../scripts/pusher-id.patch

echo "Applying pusher data additional properties patch"
git apply ../scripts/additional-properties.patch

echo "Applying room send max body size patch"
git apply ../scripts/room-send-max-body-size.patch

echo "Applying add media types patch"
git apply ../scripts/add-media-types.patch

echo "Applying relations patch"
git apply ../scripts/relations.patch

echo "Applying one time keys hack"
git apply ../scripts/one-time-keys-hack.patch

echo "Applying additional properties for LoginFlow patch"
git apply ../scripts/login-flow-additional-properties.patch

echo "Applying authentication for profile requests patch"
git apply ../scripts/auth-profile.patch

echo "Applying no enum for room summary encryption algorithm"
git apply ../scripts/room-summary-encryption.patch

echo "Applying no one of patch"
git apply ../scripts/no-one-of.patch

echo "Applying get room state"
git apply ../scripts/get-room-state.patch

echo "Applying space hierarchy patch"
git apply ../scripts/space-hierarchy.patch

)
fi

(cd matrix-spec && python3.12 -m venv sourcegen; source sourcegen/bin/activate; pip3 install -r scripts/requirements.txt &&  python3.12 ./scripts/dump-openapi.py && deactivate)
rm -f matrix.json
< matrix-spec/scripts/openapi/api-docs.json \
sed 's`](/`](https://spec.matrix.org/unstable/`g' |
jq '.paths |= with_entries(
  if .key | contains("/room_keys/") or contains("/keys/device_signing") then .key |= sub("/r0/";"/unstable/") else . end
)' \
> matrix.json
