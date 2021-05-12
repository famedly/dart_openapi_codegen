import 'package:yaml/yaml.dart';

import 'dart:convert';
import 'dart:collection';
import 'dart:io';

extension Capitalization on String {
  String get capitalized => this[0].toUpperCase() + substring(1);
  String get uncapitalized => this[0].toLowerCase() + substring(1);
}

String className(String s) => fixup(s
    .split(RegExp('[- _:./{}<>]'))
    .where((x) => x.isNotEmpty)
    .map((x) => x.capitalized)
    .join(''));

String variableName(String s) => className(s).uncapitalized;

String fixup(String s) =>
    ['default', 'is'].contains(s.toLowerCase()) ? s + '\$' : s;

String stripDoc(String s) =>
    s.replaceAll(RegExp('/\\*(\\*(?!/)|[^*])*\\*/'), '');

abstract class Schema {
  String get dartType;
  String get definition;
  String dartFromJson(String input);
  List<DefinitionSchema> get definitionSchemas;

  factory Schema.fromJson(Map<String, dynamic> json, String baseName,
      {bool required = true}) {
    if (!required) return OptionalSchema(Schema.fromJson(json, baseName));
    final type = json['type'];
    if (type is List) {
      if (type.length == 2 && type[0] is String && type[1] == 'null') {
        return Schema.fromJson({...json, 'type': type[0]}, baseName);
      } else {
        return UnknownSchema();
      }
    } else if (type == 'object' || json['allOf'] != null) {
      if (json['properties'] == null &&
          json['additionalProperties'] == null &&
          json['allOf'] == null) {
        return MapSchema.freeForm();
      }
      final obj = ObjectSchema.fromJson(json, baseName);
      if (obj.allProperties.isEmpty) {
        if (obj.inheritedAdditionalProperties != null) {
          return MapSchema.fromJson(json, baseName);
        } else {
          return VoidSchema();
        }
      }
      return obj;
    } else if (type == 'array') {
      return ArraySchema.fromJson(json, baseName);
    } else if (json['enum'] != null) {
      return EnumSchema.fromJson(json, baseName);
    } else {
      return UnknownSchema.fromJson(json);
    }
  }
}

abstract class DefinitionSchema extends Schema {
  abstract String title;
  abstract String nameSource;
  String? get description;

  factory DefinitionSchema._() => throw UnimplementedError();
}

class ObjectParam {
  Schema schema;
  String? description;
  ObjectParam(this.schema, [this.description]);
  ObjectParam.fromJson(Map<String, dynamic> json, String baseName,
      {bool required = true})
      : schema = Schema.fromJson({...json, 'description': null}, baseName,
            required: required),
        description = json['description'];
}

class ObjectSchema implements DefinitionSchema {
  Map<String, ObjectParam> properties;
  Map<String, ObjectParam> get inheritedProperties =>
      Map.fromEntries(baseClasses.expand((c) => c.allProperties.entries));
  Map<String, ObjectParam> get allProperties {
    if (properties.keys.any((k) => inheritedProperties.keys.contains(k))) {
      print('${className(title)} bad');
      baseClasses.clear();
    }
    return inheritedProperties..addAll(properties);
  }

  Map<String, ObjectParam> get dartAllProperties => {
        ...allProperties,
        if (inheritedAdditionalProperties != null)
          'additionalProperties': ObjectParam(inheritedAdditionalProperties!),
      };

  Schema? additionalProperties;
  Schema? get inheritedAdditionalProperties {
    final res =
        baseClasses.map((x) => x.additionalProperties).whereType<Schema>();
    return additionalProperties ?? (res.isNotEmpty ? res.single : null);
  }

  List<ObjectSchema> baseClasses;
  @override
  String title;
  @override
  String nameSource;
  @override
  String? description;
  @override
  String get dartType => className(title);
  @override
  String dartFromJson(String input) => '$dartType.fromJson($input)';
  @override
  String get dartToJsonMap =>
      '{\n' +
      (inheritedAdditionalProperties != null
          ? '      ...additionalProperties,\n'
          : '') +
      properties.entries
          .map((e) => "      '${e.key}': ${variableName(e.key)},\n")
          .join('') +
      '    }';
  @override
  String get definition =>
      'class $dartType ${baseClasses.isNotEmpty ? 'implements ${baseClasses.map((c) => className(c.title)).join(', ')} ' : ''}{\n'
          '  $dartType({\n' +
      allProperties.entries
          .map((e) => '    required this.${variableName(e.key)},\n')
          .join() +
      (inheritedAdditionalProperties != null
          ? '    this.additionalProperties = const {},\n'
          : '') +
      '  });\n\n' +
      '  $dartType.fromJson(Map<String, dynamic> json) :\n' +
      allProperties.entries
          .map((e) =>
              '    ${variableName(e.key)} = ${e.value.schema.dartFromJson("json['${e.key}']")}')
          .followedBy([
        if (inheritedAdditionalProperties != null)
          '    additionalProperties = Map.fromEntries(json.entries.where((e) => ![${allProperties.keys.map((k) => "'$k'").join(', ')}].contains(e.key)).map((e) => MapEntry(e.key, ${inheritedAdditionalProperties!.dartFromJson('e.value')})))'
      ]).join(',\n') +
      ';\n'
          '  Map<String, dynamic> toJson() => $dartToJsonMap;\n' +
      allProperties.entries
          .map((e) =>
              '  /** ${e.value.description ?? ''} */\n  ${e.value.schema.dartType} ${variableName(e.key)};\n')
          .join('') +
      (inheritedAdditionalProperties != null
          ? '  Map<String, ${inheritedAdditionalProperties!.dartType}> additionalProperties;\n'
          : '') +
      '}\n';
  @override
  List<DefinitionSchema> get definitionSchemas => allProperties.values
      .expand((x) => x.schema.definitionSchemas)
      .followedBy(additionalProperties?.definitionSchemas ?? [])
      .followedBy(baseClasses.expand((c) => c.definitionSchemas))
      .followedBy([this]).toList();

  ObjectSchema._fromJson(Map<String, dynamic> json, String baseName)
      : properties = SplayTreeMap.from((json['properties'] as Map? ?? {}).map(
            (k, v) => MapEntry(
                k,
                ObjectParam.fromJson(v, className(k),
                    required: json['required']?.contains(k) ?? false)))),
        additionalProperties = (json['additionalProperties'] != null)
            ? Schema.fromJson(
                json['additionalProperties'] is Map
                    ? json['additionalProperties']
                    : {},
                className(baseName))
            : null,
        title = json['title'] ?? baseName,
        nameSource = json['title'] == null ? 'generated' : 'spec',
        description = json['description'],
        baseClasses = (json['allOf'] as List? ?? [])
            .map((j) => Schema.fromJson(j, baseName) as ObjectSchema)
            .toList();

  factory ObjectSchema.fromJson(Map<String, dynamic> json, String baseName) {
    final schema = ObjectSchema._fromJson(json, baseName);
    return schema.baseClasses.length == 1 && schema.properties.isEmpty
        ? schema.baseClasses.single
        : schema;
  }
}

class MapSchema implements Schema {
  Schema? valueSchema;

  @override
  String get dartType => 'Map<String, ${valueSchema?.dartType ?? 'dynamic'}>';
  @override
  String dartFromJson(String input) => valueSchema != null
      ? '($input as Map<String, dynamic>).map((k, v) => MapEntry(k, ${valueSchema!.dartFromJson('v')}))'
      : '$input as Map<String, dynamic>';
  @override
  String get definition => '';
  @override
  List<DefinitionSchema> get definitionSchemas =>
      valueSchema?.definitionSchemas ?? [];

  MapSchema.freeForm();
  MapSchema.fromJson(Map<String, dynamic> json, String baseName)
      : valueSchema = json['additionalProperties'] != null
            ? Schema.fromJson(json['additionalProperties'], baseName)
            : null;
}

class ArraySchema implements Schema {
  Schema items;
  @override
  String get dartType => 'List<${items.dartType}>';
  @override
  String dartFromJson(String input) =>
      '($input as List).map((v) => ${items.dartFromJson('v')}).toList()';
  @override
  List<DefinitionSchema> get definitionSchemas => items.definitionSchemas;

  @override
  String get definition => items.definition;

  ArraySchema.fromJson(Map<String, dynamic> json, String baseName)
      : items = Schema.fromJson(json['items'], baseName);
}

class EnumSchema implements DefinitionSchema {
  @override
  String title;
  @override
  String nameSource = 'generated';
  List<String> values;
  @override
  String get dartType => title;
  @override
  String dartFromJson(String input) =>
      '{${values.map((v) => "'$v': $dartType.${variableName(v)}").join(', ')}}[$input]!';
  @override
  String get definition =>
      'enum $dartType {\n  ${(values.toList()..sort()).map(variableName).join(', ')}\n}\n';
  @override
  String? description;
  @override
  List<DefinitionSchema> get definitionSchemas => [this];

  EnumSchema.fromJson(Map<String, dynamic> json, String baseName)
      : title = baseName,
        values = json['enum'].cast<String>(),
        description = json['description'];
}

class UnknownSchema implements Schema {
  String? type;
  @override
  String get dartType =>
      {
        'string': 'String',
        'integer': 'int',
        'boolean': 'bool',
        'file': 'FileResponse'
      }[type] ??
      'dynamic';
  @override
  String dartFromJson(String input) =>
      type == 'file' ? 'ignoreFile($input)' : '$input as $dartType';
  @override
  String get definition => '';
  @override
  List<DefinitionSchema> get definitionSchemas => [];

  UnknownSchema();
  UnknownSchema.fromJson(Map<String, dynamic> json) : type = json['type'];
}

class VoidSchema implements Schema {
  @override
  String get dartType => 'void';
  @override
  String get definition => '';
  @override
  String dartFromJson(String input) => 'ignore($input)';
  @override
  List<DefinitionSchema> get definitionSchemas => [];
}

class OptionalSchema implements Schema {
  @override
  String get dartType => '${inner.dartType}?';
  @override
  String get definition => inner.definition;
  @override
  String dartFromJson(String input) =>
      '((v) => v != null ? ${inner.dartFromJson('v')} : null)($input)';
  @override
  List<DefinitionSchema> get definitionSchemas => inner.definitionSchemas;
  Schema inner;
  OptionalSchema._(this.inner);
  factory OptionalSchema(Schema schema) =>
      schema is OptionalSchema ? schema : OptionalSchema._(schema);
}

enum ParameterType { path, query, body, header }

class Parameter {
  Schema schema;
  ParameterType type;
  String? description;
  Parameter(this.schema, this.type, [this.description]);

  Parameter.fromJson(Map<String, dynamic> json, String baseName)
      : schema = Schema.fromJson(
            json['schema'] ?? {...json, 'description': null},
            className(
                json['in'] != 'body' ? json['name'] : baseName + 'Request'),
            required: json['required'] ?? false),
        type = ParameterType.values
            .singleWhere((x) => x.toString().split('.').last == json['in']),
        description = json['description'];
}

class Operation {
  Operation(
      {required this.id,
      required this.description,
      required this.path,
      required this.method,
      required this.response,
      required this.accessToken,
      required this.deprecated,
      required this.unpackedBody,
      this.parameters = const {}});
  String id;
  String? description;
  String path;
  String method;
  Schema? response;
  bool accessToken;
  bool deprecated;
  bool unpackedBody;
  Map<String, Parameter> parameters;
  Map<String, Parameter> get queryParameters => Map.fromEntries(
      parameters.entries.where((e) => e.value.type == ParameterType.query));
  Map<String, Parameter> get dartParameters => unpackedBody
      ? Map.fromEntries(parameters.entries.expand((e) {
          final s = e.value.schema;
          if (e.value.type == ParameterType.body && s is ObjectSchema) {
            return s.dartAllProperties.entries.map((e) => MapEntry(
                e.key,
                Parameter(
                    e.value.schema, ParameterType.body, e.value.description)));
          }
          return [e];
        }))
      : parameters;
  Set<DefinitionSchema> get definitionSchemas => {
        ...dartParameters.values
            .expand((param) => param.schema.definitionSchemas),
        if (response != null) ...response!.definitionSchemas
      };

  String get dartUriString =>
      "'" +
      path
          .split('/')
          .map((c) => (c.startsWith('{') && c.endsWith('}'))
              ? '\${Uri.encodeComponent(${c.substring(1, c.length - 1)}.toString())}'
              : c)
          .join('/') +
      "'";

  String get dartQueryMap =>
      '{\n' +
      parameters.entries
          .where((e) => e.value.type == ParameterType.query)
          .map((e) => "      '${e.key}': ${variableName(e.key)}.toString(),\n")
          .join('') +
      '    }';

  String? get dartBody {
    final bodyParams =
        parameters.entries.where((e) => e.value.type == ParameterType.body);
    if (bodyParams.isEmpty) return null;
    final bodyParam = bodyParams.single;
    final bodySchema = bodyParam.value.schema;
    if (unpackedBody && bodySchema is ObjectSchema) {
      return bodySchema.dartToJsonMap;
    }
    return variableName(bodyParam.key);
  }
}

List<Operation> operationsFromApi(Map<String, dynamic> api) {
  final operations = <Operation>[];
  final Map<String, dynamic> paths = api['paths'];
  paths.forEach((path, methods) {
    methods.cast<String, Map<String, dynamic>>().forEach((method, mcontent) {
      final param = Map<String, Parameter>.fromEntries(
          (mcontent['parameters'] as List<dynamic>? ?? []).map((parameter) =>
              MapEntry(
                  variableName(parameter['name']),
                  Parameter.fromJson(
                      parameter, className(mcontent['operationId'])))));

      final Map<String, dynamic> responses = mcontent['responses'];
      Schema? responseSchema;
      responses.forEach((response, rcontent) {
        final Map<String, dynamic>? schema = rcontent['schema'];
        if (schema != null) {
          final ps = Schema.fromJson(
              schema,
              className(mcontent['operationId']) +
                  (response == '200' ? 'Response' : className(response)));
          if (response == '200') responseSchema = ps;
        }
      });

      operations.add(Operation(
        id: mcontent['operationId'],
        description: mcontent['description'],
        path: path,
        method: method,
        response: responseSchema,
        parameters: param,
        accessToken: mcontent['security']?[0]?['accessToken'] != null,
        deprecated: mcontent['deprecated'] ?? false,
        unpackedBody: true,
      ));
    });
  });
  return operations;
}

void applyRules(List<Operation> operations, List<dynamic> rules) {
  final definitionSchemas = operations.expand((op) => op.definitionSchemas);
  final definitionSchemasMap = <String, List<DefinitionSchema>>{};
  for (final schema in definitionSchemas) {
    (definitionSchemasMap[schema.dartType] ??= []).add(schema);
  }

  for (final rule in rules) {
    final String from = rule['from'], to = rule['to'];
    final String? property = rule['property'],
        baseOf = rule['baseOf'],
        usedBy = rule['usedBy'],
        base = rule['base'];
    final bool? isEnum = rule['enum'];
    final candidates = (definitionSchemasMap[from] ?? []);
    final matchedSources = <String>{};
    for (final candidate in candidates) {
      if ((property == null ||
              (candidate is ObjectSchema &&
                  candidate.properties[property] != null)) &&
          (baseOf == null ||
              (definitionSchemasMap[baseOf] ?? []).any((c) =>
                  c is ObjectSchema && c.baseClasses.contains(candidate))) &&
          (usedBy == null ||
              (definitionSchemasMap[usedBy] ?? [])
                  .any((c) => c.definitionSchemas.contains(candidate)) ||
              operations
                  .where((op) => op.id == usedBy)
                  .any((op) => op.definitionSchemas.contains(candidate))) &&
          (base == null ||
              (candidate is ObjectSchema &&
                  candidate.baseClasses.any((b) => b.title == base))) &&
          (isEnum == null || isEnum == candidate is EnumSchema)) {
        matchedSources.add(candidate.definition);
      }
    }
    for (final candidate in candidates) {
      if (matchedSources.contains(candidate.definition)) {
        candidate.title = to;
        candidate.nameSource = 'rule override ${candidate.nameSource}';
      }
    }
  }
}

void numberConflicts(List<Operation> operations) {
  final definitionSchemas = operations.expand((op) => op.definitionSchemas);
  final definitionSchemasMap = <String, List<DefinitionSchema>>{};
  for (final schema in definitionSchemas) {
    (definitionSchemasMap[schema.dartType] ??= []).add(schema);
  }

  for (final duplicates in definitionSchemasMap.values) {
    final defs = duplicates.map((x) => x.definition).toSet();
    if (defs.length > 1) {
      final defList = defs.toList();
      var prevDefs = Map<Schema, String>.fromEntries(
          duplicates.map((d) => MapEntry(d, d.definition)));
      duplicates
          .forEach((d) => d.title += '\$${defList.indexOf(prevDefs[d]!) + 1}');
    }
  }
}

void resolveDocConflicts(List<Operation> operations) {
  final definitionSchemas = operations.expand((op) => op.definitionSchemas);
  final stripDocMap = <String, List<DefinitionSchema>>{};
  for (final schema in definitionSchemas) {
    (stripDocMap[stripDoc(schema.definition)] ??= []).add(schema);
  }
  stripDocMap.values.forEach((duplicates) {
    if (duplicates.any((x) => x.definition != duplicates.first.definition)) {
      duplicates.forEach((schema) => (schema as ObjectSchema)
          .properties
          .values
          .forEach((p) => p.description = null));
    }
  });
}

String generateModel(List<Operation> operations) {
  final definitionSchemas = operations.expand((op) => op.definitionSchemas);
  final definitionSchemasMap = <String, List<DefinitionSchema>>{};
  for (final schema in definitionSchemas) {
    (definitionSchemasMap[schema.dartType] ??= []).add(schema);
  }

  return "import 'internal.dart';\n\nclass _NameSource { final String source; const _NameSource(this.source); }\n\n" +
      definitionSchemasMap.values
          .map((v) =>
              '/** ' +
              v
                  .where((v) => v.description != null)
                  .map((v) => '${v.description}\n')
                  .toSet()
                  .toList()
                  .join('') +
              '*/\n' +
              "@_NameSource('${v.first.nameSource}')\n" +
              v.first.definition)
          .join('\n');
}

String generateApi(List<Operation> operations) {
  var ops =
      "import 'model.dart';\nimport 'fixed_model.dart';\nimport 'internal.dart';\n\n";
  ops +=
      "import 'package:http/http.dart';\nimport 'dart:convert';\n\nclass Api {\n  Uri? baseUri;\n  String? bearerToken;\n  Client httpClient = Client();\n  Api({this.baseUri, this.bearerToken});\n";
  for (final op in operations) {
    ops += '\n';
    ops +=
        '  /** ${((op.description ?? '') + op.dartParameters.entries.where((e) => e.value.description != null).map((e) => '\n\n[${variableName(e.key)}] ${e.value.description}').join('')).replaceAll('\n', '\n    ')}\n  */\n';
    if (op.deprecated) ops += '  @deprecated\n';
    ops +=
        '  Future<${op.response?.dartType ?? 'void'}> ${variableName(op.id)}(${op.dartParameters.entries.map((e) => '${e.value.schema.dartType} ${variableName(e.key)}').join(', ')}) async {\n';
    ops += '    final requestUri = Uri(path: ${op.dartUriString}';
    if (op.queryParameters.isNotEmpty) {
      ops += ', queryParameters: ${op.dartQueryMap}';
    }
    ops += ');\n';
    ops +=
        "    final request = Request('${op.method.toUpperCase()}', baseUri!.resolveUri(requestUri));\n";
    if (op.accessToken) {
      ops +=
          "    request.headers['authorization'] = 'Bearer \${bearerToken!}';\n";
    }
    if (op.dartBody != null) {
      ops += "    request.headers['content-type'] = 'application/json';\n"
          '    request.bodyBytes = utf8.encode(jsonEncode(${op.dartBody!}));\n';
    }
    ops += '    final response = await httpClient.send(request);\n';
    ops += '    final responseBody = await response.stream.toBytes();\n';
    ops += '    final responseString = utf8.decode(responseBody);\n';
    ops += '    final json = jsonDecode(responseString);\n';
    ops += '    return ${op.response?.dartFromJson('json') ?? 'null'};\n';
    ops += '  }\n';
  }
  ops += '}\n';
  return ops;
}

void main(List<String> arguments) async {
  final outputDir = Directory(arguments[0]);
  Map<String, dynamic> api =
      jsonDecode(await File(arguments[1]).readAsString());
  List<dynamic> rules = arguments.length > 2
      ? loadYaml(await File(arguments[2]).readAsString())
      : [];

  final operations = operationsFromApi(api);
  resolveDocConflicts(operations);
  applyRules(operations, rules);
  numberConflicts(operations);
  final model = generateModel(operations);
  final dartApi = generateApi(operations);
  await File.fromUri(outputDir.uri.resolve('model.dart')).writeAsString(model);
  await File.fromUri(outputDir.uri.resolve('api.dart')).writeAsString(dartApi);
}
