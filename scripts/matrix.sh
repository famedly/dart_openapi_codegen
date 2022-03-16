#!/bin/sh -e
OUTPUT=${1?Output directory like matrix_api_lite/lib/src/generated}
./scripts/prepare_matrix.sh
cp output/*.dart "$1"/
dart run dart_openapi_codegen "$1" matrix.json rules/matrix.yaml
# to make the sed command work on macos, use a backupfile
sed -i'.bakmacoscompat' s/RoomKeysRequired/RoomKeys/g "$1"/api.dart
dart format --fix "$1"/
