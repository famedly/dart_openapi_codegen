import 'package:collection/collection.dart';
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

// quirk: ignore meaningless titles like 'body'
String? fixTitle(String? s) => s != 'body' ? s : null;

abstract class Schema {
  String get dartType;
  String? get dartDefault => null;
  String dartCondition(String input) => '';
  String dartFromJson(String input);
  String dartToJson(String input) => input;
  String dartToJsonEntry(String key, String input) =>
      "${dartCondition(input)}'$key': ${dartToJson(input)}";
  String dartToQuery(String input) {
    throw Exception('$dartType not supported as query parameter');
  }

  String dartToQueryEntry(String key, String input) =>
      "${dartCondition(input)}'$key': ${dartToQuery(input)}";
  bool get dartNeedFinal => false;

  List<DefinitionSchema> get definitionSchemas => [];
  void replaceSchema(Schema from, Schema to) {}

  Schema();

  factory Schema.fromJson(Map<String, Object?> json, String baseName,
      {bool required = true}) {
    if (!required) return OptionalSchema(Schema.fromJson(json, baseName));
    final type = json['type'];
    if (type is List) {
      if (type.length == 2 && type[0] is String && type[1] == 'null') {
        return OptionalSchema(
            Schema.fromJson({...json, 'type': type[0]}, baseName));
      } else {
        return Schema.dynamicSchema;
      }
    } else if (type == 'object' || json['allOf'] != null) {
      if (json['properties'] == null &&
          json['additionalProperties'] == null &&
          json['patternProperties'] == null &&
          json['allOf'] == null) {
        return MapSchema();
      }
      final obj = ObjectSchema.fromJson(json, baseName);
      if (obj.allProperties.isEmpty) {
        if (obj.inheritedAdditionalProperties != null) {
          return MapSchema.fromJson(json, baseName);
        } else {
          return Schema.voidSchema;
        }
      }
      return obj;
    } else if (type == 'array') {
      return ArraySchema.fromJson(json, baseName);
    } else if (json['enum'] != null) {
      return EnumSchema.fromJson(json, baseName);
    } else {
      return SingletonSchema.fromJson(json);
    }
  }

  Schema get nonOptional => this;

  static final dynamicSchema = SingletonSchema('Object?');
  static final voidSchema = SingletonSchema('void',
      fromJson: (x) => 'ignore($x)', toJson: (_) => '{}');
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

  DefinitionSchema.fromJson(Map<String, Object?> json, String baseName)
      : title = (json.containsKey('title') && json['title'] is String
                ? fixTitle(json['title'] as String)
                : null) ??
            baseName,
        nameSource = (json.containsKey('title') && json['title'] is String
                    ? fixTitle(json['title'] as String)
                    : null) ==
                null
            ? 'generated'
            : 'spec',
        description =
            json['description'] != null ? json['description'] as String : '';
}

class ObjectParam {
  Schema schema;
  String? description;
  ObjectParam(this.schema, [this.description]);
  ObjectParam.fromJson(Map<String, Object?> json, String baseName,
      {bool required = true})
      : schema = Schema.fromJson({...json, 'description': null}, baseName,
            required: required),
        description = json.containsKey('description')
            ? json['description'] as String
            : '';
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
  String dartFromJson(String input) =>
      '$dartType.fromJson($input as Map<String, Object?>)';
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

  String get dartToJsonBody {
    final declarations = allProperties.entries
        .where((e) => e.value.schema.dartNeedFinal)
        .map((e) => variableName(e.key))
        .map((x) => '    final $x = this.$x;\n')
        .join('');
    return declarations.isEmpty
        ? '=> $dartToJsonMap;'
        : '{\n$declarations    return $dartToJsonMap;\n  }';
  }

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
      '  $dartType.fromJson(Map<String, Object?> json) :\n' +
      allProperties.entries
          .map((e) =>
              '    ${variableName(e.key)} = ${e.value.schema.dartFromJson("json['${e.key}']")}')
          .followedBy([
        if (inheritedAdditionalProperties != null)
          '    additionalProperties = Map.fromEntries(json.entries.where((e) => ![${allProperties.keys.map((k) => "'$k'").join(', ')}].contains(e.key)).map((e) => MapEntry(e.key, ${inheritedAdditionalProperties!.dartFromJson('e.value')})))'
      ]).join(',\n') +
      ';\n'
          '  Map<String, Object?> toJson() $dartToJsonBody\n' +
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
    for (final b in baseClasses) {
      b.replaceSchema(from, to);
    }
    for (final v in properties.values) {
      if (v.schema == from) {
        v.schema = to;
      } else {
        v.schema.replaceSchema(from, to);
      }
    }
    if (additionalProperties == from) {
      additionalProperties = to;
    } else {
      additionalProperties?.replaceSchema(from, to);
    }
  }

  bool get inlinable => nameSource == 'generated';

  ObjectSchema._fromJson(Map<String, Object?> json, String baseName)
      : properties = SplayTreeMap.from(
            (json['properties'] as Map<String, Object?>? ?? <String, Object?>{})
                .map((k, v) => MapEntry(
                    k,
                    ObjectParam.fromJson(
                        v as Map<String, Object?>, className(k),
                        required: json['required'] != null
                            ? (json['required'] as List<Object?>).contains(k)
                            : false)))),
        // yes ik what if both additionalProperties and patternProperties popup
        // at the same time? guess what, you have to fix it now!
        additionalProperties = (json['additionalProperties'] != null)
            ? Schema.fromJson(
                json['additionalProperties'] is Map
                    ? json['additionalProperties'] as Map<String, Object?>
                    : <String, Object?>{},
                className(baseName))
            : (json['patternProperties'] != null)
                ? Schema.fromJson(
                    json['patternProperties'] is Map
                        ? ((json['patternProperties'] as Map<String, Object?>)
                            .values
                            .firstOrNull as Map<String, Object?>)
                        : <String, Object?>{},
                    className(baseName))
                : null,
        baseClasses = (json['allOf'] as List? ?? [])
            .map((j) => Schema.fromJson(j as Map<String, Object?>, baseName)
                as ObjectSchema)
            .toList(),
        super.fromJson(json, baseName);

  factory ObjectSchema.fromJson(Map<String, Object?> json, String baseName) {
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
  String get dartType => 'Map<String, ${valueSchema?.dartType ?? 'Object?'}>';
  @override
  String? get dartDefault => defaultEmpty ? '{}' : null;
  @override
  String dartFromJson(String input) => valueSchema != null
      ? '($input as Map<String, Object?>).map((k, v) => MapEntry(k, ${valueSchema!.dartFromJson('v')}))'
      : '$input as Map<String, Object?>';
  @override
  String dartToJson(String input) => valueSchema != null
      ? '$input.map((k, v) => MapEntry(k, ${valueSchema!.dartToJson('v')}))'
      : input;
  @override
  List<DefinitionSchema> get definitionSchemas =>
      valueSchema?.definitionSchemas ?? [];

  @override
  String dartToQuery(String input) => 'utf8.encode(jsonEncode($input))';

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
  MapSchema.fromJson(Map<String, Object?> json, String baseName)
      // yes ik what if both additionalProperties and patternProperties popup
      // at the same time? guess what, you have to fix it now!
      : valueSchema = json['additionalProperties'] != null
            ? Schema.fromJson(
                json['additionalProperties'] as Map<String, Object?>, baseName)
            : json['patternProperties'] != null
                ? Schema.fromJson(
                    (json['patternProperties'] as Map<String, Object?>)
                        .values
                        .firstOrNull as Map<String, Object?>,
                    baseName)
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
  String dartToQuery(String input) =>
      '$input.map((v) => ${items.dartToQuery('v')}).toList()';
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

  ArraySchema.fromJson(Map<String, Object?> json, String baseName)
      : items =
            Schema.fromJson(json['items'] as Map<String, Object?>, baseName);
}

class EnumSchema extends DefinitionSchema {
  List<String> values;
  @override
  String dartFromJson(String input) =>
      '$dartType.values.fromString($input as String)!';
  @override
  String dartToJson(String input) => '$input.name';
  @override
  String dartToQuery(String input) => dartToJson(input);
  @override
  String get definition =>
      super.definition +
      '@EnhancedEnum()\nenum $dartType {\n  ${(values.toList()..sort()).map((v) => '@EnhancedEnumValue(name: \'$v\')\n' + variableName(v)).join(',\n')}\n}\n';
  @override
  List<DefinitionSchema> get definitionSchemas => [this];

  EnumSchema.fromJson(Map<String, Object?> json, String baseName)
      : values = (json['enum'] as List<dynamic>)
            .map((dynamic item) => item.toString())
            .toList(),
        super(
            title: baseName,
            nameSource: 'generated',
            description: json['description'] != null
                ? json['description'] as String
                : '');
}

class SingletonSchema extends Schema {
  static String _id(String input) => input;
  static String _toString(String input) => '$input.toString()';
  static String _throw(String input) {
    throw Exception('invalid conversion');
  }

  SingletonSchema(
    this.dartType, {
    this.fromJson,
    this.toJson = _id,
    this.toQuery = _toString,
  });

  @override
  final String dartType;
  @override
  String dartFromJson(String input) =>
      fromJson?.call(input) ?? '$input as $dartType';
  @override
  String dartToJson(String input) => toJson(input);
  @override
  String dartToQuery(String input) => toQuery(input);

  final String Function(String input)? fromJson;
  final String Function(String input) toJson;
  final String Function(String input) toQuery;

  static final map = {
    'string': SingletonSchema('String', toQuery: _id),
    'string/uri': SingletonSchema('Uri',
        fromJson: (x) => 'Uri.parse($x as String)',
        toJson: (x) => '$x.toString()'),
    'string/mx-mxc-uri': SingletonSchema('Uri',
        fromJson: (x) =>
            '(($x as String).startsWith("mxc://") ? Uri.parse($x as String) : throw Exception("Uri not an mxc URI"))',
        toJson: (x) => '$x.toString()'),
    'string/byte': SingletonSchema('Uint8List',
        fromJson: _throw, toJson: _throw, toQuery: _throw),
    'integer': SingletonSchema('int'),
    'number':
        SingletonSchema('double', fromJson: (x) => '($x as num).toDouble()'),
    'boolean': SingletonSchema('bool'),
    'file': SingletonSchema('FileResponse', fromJson: (x) => 'ignoreFile($x)'),
  };

  factory SingletonSchema.fromJson(Map<String, Object?> json) {
    final String? type =
        json.containsKey('type') ? json['type'] as String : null;
    final String? format =
        json.containsKey('format') ? json['format'] as String : null;
    if (type == null) return Schema.dynamicSchema;
    return map['$type/$format'] ?? map[type] ?? Schema.dynamicSchema;
  }
}

class OptionalSchema extends Schema {
  @override
  String get dartType =>
      inner.dartType.endsWith('?') ? inner.dartType : '${inner.dartType}?';
  @override
  String dartCondition(String input) => 'if ($input != null) ';
  @override
  String dartFromJson(String input) =>
      '((v) => v != null ? ${inner.dartFromJson('v')} : null)($input)';
  @override
  String dartToJson(String input) => inner.dartToJson(input);
  @override
  String dartToQuery(String input) => inner.dartToQuery(input);
  @override
  List<DefinitionSchema> get definitionSchemas => inner.definitionSchemas;
  @override
  bool get dartNeedFinal => true;
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

enum ParameterType { path, query, body, header, field }

class Parameter {
  Schema schema;
  ParameterType type;
  String? description;
  Parameter(this.schema, this.type, [this.description]);

  Parameter.fromJson(Map<String, Object?> json, String baseName)
      : schema = Schema.fromJson(
            json.containsKey('schema')
                ? json['schema'] as Map<String, Object?>
                : {...json, 'description': null},
            className(json['in'] != 'body'
                ? json['name'] as String
                : baseName + 'Request'),
            required: json.containsKey('required')
                ? json['required'] as bool
                : false),
        type = ParameterType.values
            .singleWhere((x) => x.toString().split('.').last == json['in']),
        description =
            json['description'] != null ? json['description'] as String : '';
}

class Operation {
  Operation(
      {required this.id,
      required this.description,
      required this.path,
      required this.method,
      required this.response,
      this.maxBodySize,
      required this.accessToken,
      this.accessTokenOptional = false,
      required this.deprecated,
      required this.unpackedBody,
      required this.unpackedResponse,
      this.parameters = const {}}) {
    for (final param in parameters.values) {
      final schema = param.schema;
      if (param.type == ParameterType.body && schema is OptionalSchema) {
        // quirk: forbid optional schema as body
        param.schema = schema.inner;
      }
    }
  }
  String id;
  String? description;
  String path;
  String method;
  Schema? response;
  int? maxBodySize;

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

  String get dartResponseComment {
    final _response = response;
    if (unpackedResponse &&
        _response is ObjectSchema &&
        _response.allProperties.length == 1 &&
        _response.inlinable) {
      final key = _response.allProperties.keys.single;
      final description = _response.allProperties.values.single.description;
      return '\n\nreturns `$key`${description != null ? ':\n$description' : ''}';
    }
    return '';
  }

  bool accessToken;
  bool accessTokenOptional;
  bool deprecated;
  bool unpackedBody;
  bool unpackedResponse;
  Map<String, Parameter> parameters;
  Map<String, Parameter> get queryParameters => Map.fromEntries(
      parameters.entries.where((e) => e.value.type == ParameterType.query));
  Map<String, Parameter> get headerParameters => Map.fromEntries(
      parameters.entries.where((e) => e.value.type == ParameterType.header));
  Map<String, Parameter> get fields => Map.fromEntries(
      parameters.entries.where((e) => e.value.type == ParameterType.field));
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
  Set<Schema> get allSchemas => {
        ...parameters.values.map((param) => param.schema),
        if (response != null) response!,
      };
  Set<DefinitionSchema> get allDefinitionSchemas =>
      allSchemas.expand((s) => s.definitionSchemas).toSet();
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
      // keep trailing slashes
      (path.endsWith('/') ? '/' : '') +
      "'";

  String get dartQueryMap =>
      '{\n' +
      parameters.entries
          .where((e) => e.value.type == ParameterType.query)
          .map((e) =>
              '      ${e.value.schema.dartToQueryEntry(e.key, variableName(e.key))},\n')
          .join('') +
      '    }';

  String get dartSetBody {
    final bodyParams =
        parameters.entries.where((e) => e.value.type == ParameterType.body);
    if (bodyParams.isEmpty) return '';
    final bodyParam = bodyParams.single;
    final bodySchema = bodyParam.value.schema;
    if (bodySchema == SingletonSchema.map['string/byte']) {
      return '    request.bodyBytes = ${variableName(bodyParam.key)};\n';
    }
    final jsonBody =
        (unpackedBody && bodySchema is ObjectSchema && bodySchema.inlinable)
            ? bodySchema.dartToJsonMap
            : bodySchema.dartToJson(variableName(bodyParam.key));
    return "    request.headers['content-type'] = 'application/json';\n"
        '    request.bodyBytes = utf8.encode(jsonEncode($jsonBody));\n';
  }

  String get bodySizeCheck {
    if (maxBodySize == null) return '';
    return '    const maxBodySize = $maxBodySize;\n'
        '    if(request.bodyBytes.length > maxBodySize) {\n'
        '      bodySizeExceeded(maxBodySize,request.bodyBytes.length);\n'
        '    }';
  }
}

List<Operation> operationsFromApi(Map<String, Object?> api) {
  final operations = <Operation>[];
  final Map<String, Object?> paths = api['paths'] as Map<String, Object?>;
  paths.forEach((path, methods) {
    print('--------------------------------------------');
    print('working on path $path');
    final params = Map<String, Parameter>.fromEntries(
        ((methods as Map<String, Object?>)['parameters'] as List<dynamic>? ??
                [])
            .map((parameter) => MapEntry(parameter['name'],
                Parameter.fromJson(parameter, className(parameter['name'])))));

    methods.cast<String, Object?>().forEach((method, mcontent) {
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
      final operationId = (mcontent as Map<String, Object?>)['operationId'] ??
          '${path.split('/').last}$method';

      print(
          'working on oid: ${operationId.toString()} method: $method, content: $mcontent');
      final localParams = mcontent['parameters'] == null
          ? <String, Parameter>{}
          : Map<String, Parameter>.fromEntries(
              (mcontent['parameters'] as List<dynamic>).map((parameter) =>
                  MapEntry(
                      parameter['name'],
                      Parameter.fromJson(
                          parameter, className(operationId as String)))));

      final requestBodyParams = mcontent['requestBody'] == null
          ? <String, Parameter>{}
          : Map<String, Parameter>.fromEntries({
              MapEntry<String, Parameter>(
                (mcontent['requestBody'] as Map)['name'] ?? 'body',
                Parameter.fromJson(
                  {
                    'in': 'body',
                    'name': (mcontent['requestBody'] as Map)['name'] ?? 'body',
                    'description':
                        (mcontent['requestBody'] as Map)['description'],
                    'required': (mcontent['requestBody'] as Map)['required'],
                    'schema':
                        ((mcontent['requestBody'] as Map)['content'] as Map)
                                .values
                                .single?['schema'] ??
                            <String, Object?>{},
                  },
                  className(operationId as String),
                ),
              ),
            });

      final responses = mcontent['responses'] as Map<String, Object?>;
      // 200: example
      // 200: desc
      // 200: schema
      final responseSchemas = responses.map((response, rcontent) {
        final content = (rcontent as Map<String, Object?>)['content'];
        if (content == null) return MapEntry(response, null);
        for (final responseType in (content as Map<String, Object?>).values) {
          if (responseType == null) return MapEntry(response, null);
          final schema = rcontent['schema'] as Map<String, Object?>? ??
              (responseType as Map<String, Object?>)['schema']
                  as Map<String, Object?>?;
          if (schema != null) {
            final ps = Schema.fromJson(
                schema,
                className(operationId as String) +
                    (response == '200' ? 'Response' : className(response)));
            return MapEntry(response, ps);
          }
          return MapEntry(response, null);
        }
        return MapEntry(response, null);
      });

      // final contentSchemas = responses.map((response, rcontent) {});

      final responseSchema = responseSchemas['200'];
      var unpackedResponse = false;
      if (responseSchema is ObjectSchema) {
        // quirk: If a response contains a property like m.upload.size (dots),
        // the response should be extensible, therefore not unpacked.
        unpackedResponse =
            responseSchema.allProperties.keys.every((k) => !k.contains('.'));
      }

      final allParams = Map.fromEntries(
          {...params, ...requestBodyParams, ...localParams}.entries.toList()
            ..sort((a, b) => a.value.type.index - b.value.type.index));

      // HACK: `maxBodySize` is not a valid property in openapi but we add it in a patch. Helps throw an Exception when the body size goes beyond this value after JSON & UTF8 encoding.
      final maxBodySize = mcontent['maxBodySize'] as int?;

      operations.add(Operation(
        id: operationId as String,
        description: mcontent['description'] != null
            ? mcontent['description'] as String
            : '',
        path: path.trim(), // quirk: trim path for inviteUser
        method: method,
        response: responseSchema,
        parameters: allParams,
        maxBodySize: maxBodySize,
        accessToken: (mcontent.containsKey('security')
            ? (mcontent['security'] as List<Object?>).isNotEmpty
            : false),
        accessTokenOptional: (mcontent.containsKey('security')
            ? (mcontent['security'] as List<Object?>).isNotEmpty &&
                (mcontent['security'] as List<Object?>).singleWhereOrNull(
                      (element) => element.toString() == '{}',
                    ) !=
                    null
            : false),
        deprecated: mcontent.containsKey('deprecated')
            ? mcontent['deprecated'] as bool
            : false,
        unpackedBody: true,
        unpackedResponse: unpackedResponse,
      ));
    });
  });
  return operations;
}

void applyRenameRules(List<Operation> operations, List<dynamic> renameRules) {
  final definitionSchemas =
      operations.expand((op) => op.allDefinitionSchemas).toSet();
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
  return "import 'internal.dart';\nimport 'package:enhanced_enum/enhanced_enum.dart';\npart 'model.g.dart';\nclass _NameSource { final String source; const _NameSource(this.source); }\n\n" +
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
      "import 'package:http/http.dart';\nimport 'dart:convert';\nimport 'dart:typed_data';\n\nclass Api {\n  Client httpClient;\n  Uri? baseUri;\n  String? bearerToken;\n  Api({Client? httpClient, this.baseUri, this.bearerToken})\n    : httpClient = httpClient ?? Client();\n"
      "  Never unexpectedResponse(BaseResponse response, Uint8List body) { throw Exception('http error response'); }\n"
      "  Never bodySizeExceeded(int expected, int actual) { throw Exception('body size \$actual exceeded \$expected'); }\n";
  for (final op in operations) {
    print('--------------------------------------------');
    print(op.path);
    print(op.dartResponse.runtimeType);
    print(op.dartResponse?.dartType.toString());

    if (op.accessTokenOptional) {
      op.parameters.addAll({
        'sendToken': Parameter(
          OptionalSchema(SingletonSchema('bool')),
          ParameterType.field,
        ),
      });
    }

    ops += '\n';
    ops +=
        '  /// ${((op.description ?? op.id) + op.dartParameters.entries.where((e) => e.value.description != null).map((e) => '\n\n[${variableName(e.key)}] ${e.value.description}').join('') + op.dartResponseComment).replaceAll('\n', '\n  /// ')}\n';
    if (op.deprecated) ops += '  @Deprecated(\'message\')\n';
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
      if (op.accessTokenOptional) {
        ops += 'if(sendToken ?? false)';
      }
      ops +=
          "    request.headers['authorization'] = 'Bearer \${bearerToken!}';\n";
    }
    for (final e in op.headerParameters.entries) {
      ops +=
          "    ${e.value.schema.dartCondition(variableName(e.key))}request.headers['${e.key.toLowerCase()}'] = ${e.value.schema.dartToQuery(variableName(e.key))};\n";
    }
    ops += op.dartSetBody;
    ops += op.bodySizeCheck;
    ops += '    final response = await httpClient.send(request);\n';
    ops += '    final responseBody = await response.stream.toBytes();\n';
    ops +=
        '    if (response.statusCode != 200) unexpectedResponse(response, responseBody);\n';
    if (op.response == SingletonSchema.map['file']) {
      ops +=
          "    return FileResponse(contentType: response.headers['content-type'], data: responseBody);";
    } else {
      ops += '    final responseString = utf8.decode(responseBody);\n';
      ops += '    final json = jsonDecode(responseString);\n';
      ops +=
          '    return ${op.dartResponse?.dartFromJson('json${op.dartResponseExtract}') ?? 'null'};\n';
    }
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
  final Map<String, Object?> api =
      jsonDecode(await File(arguments[1]).readAsString());
  final Map rules = arguments.length > 2
      ? loadYaml(await File(arguments[2]).readAsString())
      : {};
  final List<dynamic> renameRules = rules['rename'] ?? [];
  final List<dynamic> replaceRules = rules['replace'] ?? [];
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
    final response = voidOp.response;
    if (response == Schema.voidSchema) {
      print('unneeded voidResponse: ${voidOp.id}');
    }
    if (response is ObjectSchema) {
      print('object in voidResponse: ${voidOp.id}');
    }
    voidOp.response = Schema.voidSchema;
  }
  applyRenameRules(operations, replaceRules);
  mergeDuplicates(operations);
  applyRenameRules(operations, renameRules);
  mergeDuplicates(operations);
  operations.removeWhere((op) => exclude.contains(variableName(op.id)));
  for (final schema
      in operations.expand((op) => op.definitionSchemas).toSet()) {
    if (exclude.contains(className(schema.title))) {
      final replaceSchema = ExcludedSchema(schema);
      for (final op in operations) {
        op.replaceSchema(schema, replaceSchema);
      }
    }
  }
  numberConflicts(operations);
  final model = importStr + generateModel(operations);
  final dartApi = importStr + generateApi(operations);
  await File.fromUri(outputDir.uri.resolve('model.dart')).writeAsString(model);
  await File.fromUri(outputDir.uri.resolve('api.dart')).writeAsString(dartApi);
}
