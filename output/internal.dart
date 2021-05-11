import 'fixed_model.dart';

Map<String, T> castMap<T>(dynamic input) => (input as Map).cast<String, T>();
List<T> castArray<T>(dynamic input) => (input as List).cast<T>();
void ignore(Object? input) {}
FileResponse ignoreFile(dynamic input) { throw UnimplementedError(); }
