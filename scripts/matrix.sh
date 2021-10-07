#!/bin/sh -e
OUTPUT=${1?Output directory like matrix_api_lite/lib/src/generated}
./scripts/prepare_matrix.sh
cp output/*.dart "$1"/
pub run dart_openapi_codegen "$1" matrix.json rules/matrix.yaml
sed -i s/RoomKeysRequired/RoomKeys/g "$1"/api.dart
dartfmt -w "$1"/
