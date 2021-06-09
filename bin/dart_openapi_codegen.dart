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

String stripDoc(String s) => s
    .replaceAll(RegExp('/\\*(\\*(?!/)|[^*])*\\*/[ \n]*'), '')
    .replaceAll(RegExp('@_[a-zA-Z0-9]*\\([^)]*\\)[ \n]*'), '');

abstract class Schema {
  String get dartType;
  String? get dartDefault => null;
  String dartFromJson(String input);
  String dartToJson(String input) => input;
  String dartToJsonEntry(String key, String input) =>
      "'$key': ${dartToJson(input)}";
  String dartToJsonPromotableEntry(String key, String input) =>
      dartToJsonEntry(key, input);
  String dartToQueryPromotableEntry(String key, String input) {
    final schema = nonOptional;
    return dartToJsonPromotableEntry(key, input) +
        (schema is UnknownSchema && schema.type != 'string'
            ? '.toString()'
            : '');
  }

  List<DefinitionSchema> get definitionSchemas => [];
  void replaceSchema(Schema from, Schema to) {}

  Schema();

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
        return MapSchema();
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

  Schema get nonOptional => this;
}

abstract class DefinitionSchema extends Schema {
  String title;
  String nameSource;
  String? description;
  String get definition =>
      (description
              ?.split('\n')
              .map((line) => '/// $line'.trim() + '\n')
              .join('') ??
          '') +
      "@_NameSource('$nameSource')\n";

  @override
  String get dartType => className(title);

  DefinitionSchema({
    required this.title,
    required this.nameSource,
    this.description,
  });

  DefinitionSchema.fromJson(Map<String, dynamic> json, String baseName)
      : title = json['title'] ?? baseName,
        nameSource = json['title'] == null ? 'generated' : 'spec',
        description = json['description'];
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

class ExcludedSchema extends Schema {
  Schema inner;
  ExcludedSchema._(this.inner);
  factory ExcludedSchema(Schema schema) =>
      schema is ExcludedSchema ? schema : ExcludedSchema._(schema);
  @override
  String get dartType => inner.dartType;
  @override
  String dartFromJson(String input) => inner.dartFromJson(input);
  @override
  String dartToJson(String input) => inner.dartToJson(input);
}

class ObjectSchema extends DefinitionSchema {
  Map<String, ObjectParam> properties;
  Map<String, ObjectParam> get inheritedProperties =>
      Map.fromEntries(baseClasses.expand((c) => c.allProperties.entries));
  Map<String, ObjectParam> get allProperties {
    if (properties.keys.any((k) => inheritedProperties.keys.contains(k))) {
      print('invalid base class: ${className(title)}');
      baseClasses.clear();
    }
    return inheritedProperties..addAll(properties);
  }

  Map<String, ObjectParam> get dartAllProperties => {
        ...allProperties,
        if (inheritedAdditionalProperties != null)
          'additionalProperties': ObjectParam(
              MapSchema.defaultEmpty(inheritedAdditionalProperties!)),
      };

  Schema? additionalProperties;
  Schema? get inheritedAdditionalProperties {
    final res =
        baseClasses.map((x) => x.additionalProperties).whereType<Schema>();
    return additionalProperties ?? (res.isNotEmpty ? res.single : null);
  }

  List<ObjectSchema> baseClasses;
  @override
  String dartFromJson(String input) => '$dartType.fromJson($input)';
  @override
  String dartToJson(String input) => '$input.toJson()';

  String get dartToJsonMap =>
      '{\n' +
      (inheritedAdditionalProperties != null
          ? '      ...additionalProperties,\n'
          : '') +
      allProperties.entries
          .map((e) =>
              '      ${e.value.schema.dartToJsonEntry(e.key, variableName(e.key))},\n')
          .join('') +
      '    }';
  String get dartToJsonPromotableMap =>
      '{\n' +
      (inheritedAdditionalProperties != null
          ? '      ...additionalProperties,\n'
          : '') +
      properties.entries
          .map((e) =>
              '      ${e.value.schema.dartToJsonPromotableEntry(e.key, variableName(e.key))},\n')
          .join('') +
      '    }';
  @override
  String get definition =>
      super.definition +
      'class $dartType ${baseClasses.isNotEmpty ? 'implements ${baseClasses.map((c) => className(c.title)).join(', ')} ' : ''}{\n'
          '  $dartType({\n' +
      allProperties.entries
          .map((e) =>
              '    ${e.value.schema is OptionalSchema ? '' : 'required '}this.${variableName(e.key)},\n')
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
      dartAllProperties.entries
          .map((e) =>
              '${e.value.description?.replaceAll(RegExp('^|\n'), '\n  /// ') ?? ''}\n  ${e.value.schema.dartType} ${variableName(e.key)};\n')
          .join('') +
      '}\n';
  @override
  List<DefinitionSchema> get definitionSchemas => properties.values
      .expand((x) => x.schema.definitionSchemas)
      .followedBy(additionalProperties?.definitionSchemas ?? [])
      .followedBy(baseClasses.expand((c) => c.definitionSchemas))
      .followedBy([this]).toList();

  @override
  void replaceSchema(Schema from, Schema to) {
    if (to is ObjectSchema) {
      baseClasses = baseClasses.map((b) => b == from ? to : b).toList();
    }
    baseClasses.forEach((b) => b.replaceSchema(from, to));
    properties.values.forEach((v) {
      if (v.schema == from) {
        v.schema = to;
      } else {
        v.schema.replaceSchema(from, to);
      }
    });
    if (additionalProperties == from) {
      additionalProperties = to;
    } else {
      additionalProperties?.replaceSchema(from, to);
    }
  }

  bool get inlinable => nameSource == 'generated';

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
        baseClasses = (json['allOf'] as List? ?? [])
            .map((j) => Schema.fromJson(j, baseName) as ObjectSchema)
            .toList(),
        super.fromJson(json, baseName);

  factory ObjectSchema.fromJson(Map<String, dynamic> json, String baseName) {
    final schema = ObjectSchema._fromJson(json, baseName);
    return schema.baseClasses.length == 1 && schema.properties.isEmpty
        ? schema.baseClasses.single
        : schema;
  }
}

class MapSchema extends Schema {
  Schema? valueSchema;
  bool defaultEmpty;

  @override
  String get dartType => 'Map<String, ${valueSchema?.dartType ?? 'dynamic'}>';
  @override
  String? get dartDefault => defaultEmpty ? '{}' : null;
  @override
  String dartFromJson(String input) => valueSchema != null
      ? '($input as Map<String, dynamic>).map((k, v) => MapEntry(k, ${valueSchema!.dartFromJson('v')}))'
      : '$input as Map<String, dynamic>';
  @override
  String dartToJson(String input) => valueSchema != null
      ? '$input.map((k, v) => MapEntry(k, ${valueSchema!.dartToJson('v')}))'
      : '$input';
  @override
  List<DefinitionSchema> get definitionSchemas =>
      valueSchema?.definitionSchemas ?? [];

  @override
  void replaceSchema(Schema from, Schema to) {
    if (valueSchema == from) {
      valueSchema = to;
    } else {
      valueSchema?.replaceSchema(from, to);
    }
  }

  MapSchema([this.valueSchema]) : defaultEmpty = false;
  MapSchema.defaultEmpty([this.valueSchema]) : defaultEmpty = true;
  MapSchema.fromJson(Map<String, dynamic> json, String baseName)
      : valueSchema = json['additionalProperties'] != null
            ? Schema.fromJson(json['additionalProperties'], baseName)
            : null,
        defaultEmpty = false;
}

class ArraySchema extends Schema {
  Schema items;
  @override
  String get dartType => 'List<${items.dartType}>';
  @override
  String dartFromJson(String input) =>
      '($input as List).map((v) => ${items.dartFromJson('v')}).toList()';
  @override
  String dartToJson(String input) =>
      '$input.map((v) => ${items.dartToJson('v')}).toList()';
  @override
  List<DefinitionSchema> get definitionSchemas => items.definitionSchemas;

  @override
  void replaceSchema(Schema from, Schema to) {
    if (items == from) {
      items = to;
    } else {
      items.replaceSchema(from, to);
    }
  }

  ArraySchema.fromJson(Map<String, dynamic> json, String baseName)
      : items = Schema.fromJson(json['items'], baseName);
}

class EnumSchema extends DefinitionSchema {
  List<String> values;
  @override
  String dartFromJson(String input) =>
      '{${values.map((v) => "'$v': $dartType.${variableName(v)}").join(', ')}}[$input]!';
  @override
  String dartToJson(String input) =>
      "{${values.map((v) => "$dartType.${variableName(v)}: '$v'").join(', ')}}[$input]!";
  @override
  String get definition =>
      super.definition +
      'enum $dartType {\n  ${(values.toList()..sort()).map(variableName).join(', ')}\n}\n';
  @override
  List<DefinitionSchema> get definitionSchemas => [this];

  EnumSchema.fromJson(Map<String, dynamic> json, String baseName)
      : values = json['enum'].cast<String>(),
        super(
            title: baseName,
            nameSource: 'generated',
            description: json['description']);
}

class UnknownSchema extends Schema {
  String? type;
  @override
  String get dartType =>
      {
        'string': 'String',
        'integer': 'int',
        'number': 'double',
        'boolean': 'bool',
        'file': 'FileResponse'
      }[type] ??
      'dynamic';
  @override
  String dartFromJson(String input) =>
      type == 'file' ? 'ignoreFile($input)' : '$input as $dartType';

  UnknownSchema();
  UnknownSchema.fromJson(Map<String, dynamic> json) : type = json['type'];
}

class VoidSchema extends Schema {
  @override
  String get dartType => 'void';
  @override
  String dartFromJson(String input) => 'ignore($input)';
  @override
  String dartToJson(String input) => '{}';
}

class OptionalSchema extends Schema {
  @override
  String get dartType => '${inner.dartType}?';
  @override
  String dartFromJson(String input) =>
      '((v) => v != null ? ${inner.dartFromJson('v')} : null)($input)';
  @override
  String dartToJsonEntry(String key, String input) =>
      'if ($input != null) ${inner.dartToJsonEntry(key, '$input!')}';
  @override
  String dartToJsonPromotableEntry(String key, String input) =>
      'if ($input != null) ${inner.dartToJsonEntry(key, input)}';
  @override
  List<DefinitionSchema> get definitionSchemas => inner.definitionSchemas;
  Schema inner;
  OptionalSchema._(this.inner);
  factory OptionalSchema(Schema schema) =>
      schema is OptionalSchema ? schema : OptionalSchema._(schema);
  @override
  void replaceSchema(Schema from, Schema to) {
    if (inner == from) {
      inner = to;
    } else {
      inner.replaceSchema(from, to);
    }
  }

  @override
  Schema get nonOptional => inner;
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
      required this.unpackedResponse,
      this.parameters = const {}});
  String id;
  String? description;
  String path;
  String method;
  Schema? response;
  Schema? get dartResponse {
    final _response = response;
    return unpackedResponse &&
            _response is ObjectSchema &&
            _response.allProperties.length == 1 &&
            _response.inlinable
        ? _response.allProperties.values.single.schema
        : _response;
  }

  String? get dartResponseExtract {
    final _response = response;
    return unpackedResponse &&
            _response is ObjectSchema &&
            _response.allProperties.length == 1 &&
            _response.inlinable
        ? "['${_response.allProperties.keys.single}']"
        : '';
  }

  bool accessToken;
  bool deprecated;
  bool unpackedBody;
  bool unpackedResponse;
  Map<String, Parameter> parameters;
  Map<String, Parameter> get queryParameters => Map.fromEntries(
      parameters.entries.where((e) => e.value.type == ParameterType.query));
  Map<String, Parameter> get dartParameters => unpackedBody
      ? Map.fromEntries(parameters.entries.expand((e) {
          final s = e.value.schema;
          if (e.value.type == ParameterType.body &&
              s is ObjectSchema &&
              s.inlinable) {
            return s.dartAllProperties.entries.map((e) => MapEntry(
                e.key,
                Parameter(
                    e.value.schema, ParameterType.body, e.value.description)));
          }
          return [e];
        }))
      : parameters;
  Map<String, Parameter> get dartPositionalParameters =>
      Map.fromEntries(dartParameters.entries.where(isPositionalParameter));
  Map<String, Parameter> get dartNamedParameters => Map.fromEntries(
      dartParameters.entries.where((p) => !isPositionalParameter(p)));
  // quirk: parameter is positional if its name is the last part of the path
  bool isPositionalParameter(MapEntry<String, Parameter> e) =>
      e.value.schema.dartDefault == null && e.value.schema is! OptionalSchema ||
      path.split('/').last == e.key;
  Set<Schema> get schemas => {
        ...dartParameters.values.map((param) => param.schema),
        if (dartResponse != null) dartResponse!,
      };
  Set<DefinitionSchema> get definitionSchemas =>
      schemas.expand((s) => s.definitionSchemas).toSet();
  void replaceSchema(Schema from, Schema to) {
    for (final parameter in parameters.values) {
      if (parameter.schema == from) {
        parameter.schema = to;
      } else {
        parameter.schema.replaceSchema(from, to);
      }
    }
    if (response == from) {
      response = to;
    } else {
      response?.replaceSchema(from, to);
    }
  }

  String get dartUriString =>
      "'" +
      path
          .split('/')
          .where((c) => c.isNotEmpty)
          .map((c) => (c.startsWith('{') && c.endsWith('}'))
              ? '\${Uri.encodeComponent(${dartParameters[c.substring(1, c.length - 1)]!.schema.dartToJson(c.substring(1, c.length - 1))})}'
              : c)
          .join('/') +
      "'";

  String get dartQueryMap =>
      '{\n' +
      parameters.entries
          .where((e) => e.value.type == ParameterType.query)
          .map((e) =>
              '      ${e.value.schema.dartToQueryPromotableEntry(e.key, variableName(e.key))},\n')
          .join('') +
      '    }';

  String? get dartBody {
    final bodyParams =
        parameters.entries.where((e) => e.value.type == ParameterType.body);
    if (bodyParams.isEmpty) return null;
    final bodyParam = bodyParams.single;
    final bodySchema = bodyParam.value.schema;
    if (unpackedBody && bodySchema is ObjectSchema && bodySchema.inlinable) {
      return bodySchema.dartToJsonPromotableMap;
    }
    return variableName(bodyParam.key);
  }
}

List<Operation> operationsFromApi(Map<String, dynamic> api) {
  final operations = <Operation>[];
  final Map<String, dynamic> paths = api['paths'];
  paths.forEach((path, methods) {
    final params = Map<String, Parameter>.fromEntries(
        (methods['parameters'] as List<dynamic>? ?? []).map((parameter) =>
            MapEntry(parameter['name'],
                Parameter.fromJson(parameter, className(parameter['name'])))));
    methods.cast<String, dynamic>().forEach((method, mcontent) {
      if (!{
        'get',
        'post',
        'put',
        'delete',
        'patch',
        'options',
        'head',
        'trace',
      }.contains(method.toLowerCase())) return;
      final operationId =
          mcontent['operationId'] ?? '${path.split('/').last}$method';
      final localParams = mcontent['parameters'] == null
          ? <String, Parameter>{}
          : Map<String, Parameter>.fromEntries(
              (mcontent['parameters'] as List<dynamic>).map((parameter) =>
                  MapEntry(parameter['name'],
                      Parameter.fromJson(parameter, className(operationId)))));

      final Map<String, dynamic> responses = mcontent['responses'];
      final responseSchemas = responses.map((response, rcontent) {
        final Map<String, dynamic>? schema = rcontent['schema'];
        if (schema != null) {
          final ps = Schema.fromJson(
              schema,
              className(operationId) +
                  (response == '200' ? 'Response' : className(response)));
          return MapEntry(response, ps);
        }
        return MapEntry(response, null);
      });

      final responseSchema = responseSchemas['200'];
      var unpackedResponse = false;
      if (responseSchema is ObjectSchema) {
        unpackedResponse = responseSchema.allProperties.keys
            .every(path.split('/').last.contains);
      }

      operations.add(Operation(
        id: operationId,
        description: mcontent['description'],
        path: path,
        method: method,
        response: responseSchema,
        parameters: {...params, ...localParams},
        accessToken: mcontent['security']?[0]?['accessToken'] != null,
        deprecated: mcontent['deprecated'] ?? false,
        unpackedBody: true,
        unpackedResponse: unpackedResponse,
      ));
    });
  });
  return operations;
}

void applyRenameRules(List<Operation> operations, List<dynamic> renameRules) {
  final definitionSchemas =
      operations.expand((op) => op.definitionSchemas).toSet();
  final definitionSchemasMap = <String, List<DefinitionSchema>>{};
  for (final schema in definitionSchemas) {
    (definitionSchemasMap[schema.dartType] ??= []).add(schema);
  }

  for (final rule in renameRules) {
    final String from = rule['from'], to = rule['to'];
    final String? property = rule['property'],
        baseOf = rule['baseOf'],
        usedBy = rule['usedBy'],
        base = rule['base'];
    final bool? isEnum = rule['enum'];
    for (final candidate in (definitionSchemasMap[from] ?? [])) {
      if ((property == null ||
              (candidate is ObjectSchema &&
                  candidate.properties.keys
                      .any((p) => variableName(p) == property))) &&
          (baseOf == null ||
              (definitionSchemasMap[baseOf] ?? []).any((c) =>
                  c is ObjectSchema && c.baseClasses.contains(candidate))) &&
          (usedBy == null ||
              (definitionSchemasMap[usedBy] ?? [])
                  .any((c) => c.definitionSchemas.contains(candidate)) ||
              operations
                  .where((op) => variableName(op.id) == usedBy)
                  .any((op) => op.definitionSchemas.contains(candidate))) &&
          (base == null ||
              (candidate is ObjectSchema &&
                  candidate.baseClasses.any((b) => b.title == base))) &&
          (isEnum == null || isEnum == candidate is EnumSchema)) {
        candidate.title = to;
        candidate.nameSource = 'rule override ${candidate.nameSource}';
      }
    }
  }
}

void numberConflicts(List<Operation> operations) {
  final definitionSchemasMap = <String, Set<DefinitionSchema>>{};
  for (final schema in operations.expand((op) => op.definitionSchemas)) {
    (definitionSchemasMap[schema.dartType] ??= {}).add(schema);
  }

  for (final duplicates in definitionSchemasMap.values) {
    if (duplicates.length > 1) {
      duplicates.toList().asMap().forEach((k, v) => v.title += '\$${k + 1}');
    }
  }
}

String generateModel(List<Operation> operations) {
  return "import 'internal.dart';\n\nclass _NameSource { final String source; const _NameSource(this.source); }\n\n" +
      operations
          .expand((op) => op.definitionSchemas)
          .toSet()
          .map((v) => v.definition)
          .join('\n');
}

String generateApi(List<Operation> operations) {
  var ops =
      "import 'model.dart';\nimport 'fixed_model.dart';\nimport 'internal.dart';\n\n";
  ops +=
      "import 'package:http/http.dart';\nimport 'dart:convert';\n\nclass Api {\n  Client httpClient;\n  Uri? baseUri;\n  String? bearerToken;\n  Api({Client? httpClient, this.baseUri, this.bearerToken})\n    : httpClient = httpClient ?? Client();\n";
  for (final op in operations) {
    ops += '\n';
    ops +=
        '  /// ${((op.description ?? op.id) + op.dartParameters.entries.where((e) => e.value.description != null).map((e) => '\n\n[${variableName(e.key)}] ${e.value.description}').join('')).replaceAll('\n', '\n  \/\/\/ ')}\n';
    if (op.deprecated) ops += '  @deprecated\n';
    ops +=
        '  Future<${op.dartResponse?.dartType ?? 'void'}> ${variableName(op.id)}(${op.dartPositionalParameters.entries.map((e) => '${e.value.schema.dartType} ${variableName(e.key)}').followedBy([
          if (op.dartNamedParameters.isNotEmpty)
            '{' +
                op.dartNamedParameters.entries
                    .map((e) =>
                        '${e.value.schema.dartType} ${variableName(e.key)}${e.value.schema.dartDefault != null ? ' = const ${e.value.schema.dartDefault}' : ''}')
                    .join(', ') +
                '}'
        ]).join(', ')}) async {\n';
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
    ops +=
        "    if (response.statusCode != 200) throw Exception('http error response');\n";
    ops += '    final responseString = utf8.decode(responseBody);\n';
    ops += '    final json = jsonDecode(responseString);\n';
    ops +=
        '    return ${op.dartResponse?.dartFromJson('json${op.dartResponseExtract}') ?? 'null'};\n';
    ops += '  }\n';
  }
  ops += '}\n';
  return ops;
}

void mergeSchemas(DefinitionSchema a, DefinitionSchema b) {
  final adesc = a.description, bdesc = b.description;
  if (adesc == null) {
    a.description = bdesc;
  } else if (bdesc == null) {
    b.description = adesc;
  } else if (!adesc.contains(bdesc)) {
    b.description = a.description = '$adesc\n\n$bdesc';
  }
  if (!a.nameSource.contains(b.nameSource)) {
    b.nameSource = a.nameSource = '(${a.nameSource}, ${b.nameSource})';
  }
  if (a.definition != b.definition) {
    print('duplicates with different documentation: ${a.title}');
  }
}

void mergeDuplicates(List<Operation> operations) {
  final map = <String, DefinitionSchema>{};
  for (final operation in operations) {
    for (final schema in operation.definitionSchemas) {
      final def = stripDoc(schema.definition);
      final v = map.putIfAbsent(def, () => schema);
      if (v != schema) {
        mergeSchemas(v, schema);
        operation.replaceSchema(schema, v);
      }
    }
  }
}

void main(List<String> arguments) async {
  final outputDir = Directory(arguments[0]);
  final Map<String, dynamic> api =
      jsonDecode(await File(arguments[1]).readAsString());
  final Map rules = arguments.length > 2
      ? loadYaml(await File(arguments[2]).readAsString())
      : {};
  final List<dynamic> renameRules = rules['rename'] ?? [];
  final List<dynamic>? includeApi = rules['includeApi'];
  final List<dynamic> exclude = rules['exclude'] ?? [];
  final List<dynamic> voidResponse = rules['voidResponse'] ?? [];
  final List<dynamic> imports = rules['imports'] ?? [];
  final importStr = imports.map((path) => "import '$path';\n").join('') +
      (imports.isEmpty ? '' : '\n');

  final operations = operationsFromApi(api);
  if (includeApi != null) {
    operations.retainWhere((op) => includeApi.contains(variableName(op.id)));
  }
  for (final voidOp in operations.where((op) => voidResponse.contains(op.id))) {
    voidOp.response = VoidSchema();
  }
  mergeDuplicates(operations);
  applyRenameRules(operations, renameRules);
  mergeDuplicates(operations);
  operations.removeWhere((op) => exclude.contains(variableName(op.id)));
  for (final schema
      in operations.expand((op) => op.definitionSchemas).toSet()) {
    if (exclude.contains(className(schema.title))) {
      final replaceSchema = ExcludedSchema(schema);
      operations.forEach((op) => op.replaceSchema(schema, replaceSchema));
    }
  }
  numberConflicts(operations);
  final model = importStr + generateModel(operations);
  final dartApi = importStr + generateApi(operations);
  await File.fromUri(outputDir.uri.resolve('model.dart')).writeAsString(model);
  await File.fromUri(outputDir.uri.resolve('api.dart')).writeAsString(dartApi);
}
