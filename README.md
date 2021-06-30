# dart_openapi_codegen

Generate dart client code for OpenAPI specifications

## Set up

Call `pub get` before using the code generator.

## matrix_api_lite

To update the generated code in [matrix_api_lite](https://gitlab.com/famedly/company/frontend/libraries/matrix_api_lite), use the script:
```
./scripts/matrix.sh ../matrix_api_lite/lib/src/generated
```
The script clones and patches `matrix-doc` and generates code using the rules in `rules/matrix.yaml`.
