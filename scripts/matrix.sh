#!/bin/sh -e
./scripts/prepare_matrix.sh
cp output/*.dart "$1"/
dart run dart_openapi_codegen "$1" matrix.json rules/matrix.yaml
# to make the sed command work on macos, use a backupfile
sed -i'.bakmacoscompat' s/RoomKeysRequired/RoomKeys/g "$1"/api.dart
cd "$1"
dart format --fix .
flutter pub run import_sorter:main --no-comments
