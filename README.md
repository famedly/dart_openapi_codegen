# dart_openapi_codegen

Generate dart client code for OpenAPI specifications

## How to use

> IMPORTANT: At the moment this code generator works only with JSON formatted OpenAPI files!

1. Add this library to your dev_dependencies (Needs access to this repository via SSH):

```yaml
dev_dependencies:
  dart_openapi_codegen:
    git: git@gitlab.com:famedly/company/frontend/dart_openapi_codegen.git
```

2. Run `dart pub get`

3. Start the code generator and pass the necessary arguments:

```sh
dart_openapi_codegen <OUTPUT_DIRECTORY> <PATH_TO_OPENAPI_FILE> <OPTIONAL_RULES_FILE>
```

Examples:

```sh
// Create a simple client SDK from an openapi file:
pub run dart_openapi_codegen ./lib/src/generated ./openapi.json
```

## matrix_api_lite

To update the generated code in [matrix_api_lite](https://gitlab.com/famedly/company/frontend/libraries/matrix_api_lite), use the script:
```
./scripts/matrix.sh ../matrix_api_lite/lib/src/generated
```
The script clones and patches `matrix-doc` and generates code using the rules in `rules/matrix.yaml`.
