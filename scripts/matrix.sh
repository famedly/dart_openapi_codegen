#!/bin/sh -e
# ./scripts/prepare_matrix.sh
cp output/*.dart "$1"/
dart run dart_openapi_codegen "$1" matrix.json rules/matrix.yaml
# to make the sed command work on macos, use a backupfile
sed -i'.bakmacoscompat' s/RoomKeysRequired/RoomKeys/g "$1"/api.dart
cd "$1"
dart pub get
flutter pub run build_runner build --delete-conflicting-outputs
flutter pub run import_sorter:main --no-comments
dart format .
dart fix --apply
dart format .
dart fix --apply
flutter pub run import_sorter:main --no-comments
dart format .
dart fix --apply