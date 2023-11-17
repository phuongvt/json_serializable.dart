// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:collection/collection.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:source_gen/source_gen.dart';
import 'package:source_helper/source_helper.dart';

import '../lambda_result.dart';
import '../type_helper.dart';
import '../utils.dart';

/// A [TypeHelper] that supports classes annotated with implementations of
/// [JsonConverter].
class JsonConverterHelper extends TypeHelper<TypeHelperContextWithConfig> {
  const JsonConverterHelper();

  @override
  Object? serialize(
      DartType targetType,
      String expression,
      TypeHelperContextWithConfig context,
      ) {
    final converter = _typeConverter(targetType, context);

    if (converter == null) {
      return null;
    }

    if (!converter.fieldType.isNullableType && targetType.isNullableType) {
      const converterToJsonName = r'_$JsonConverterToJson';
      context.addMember('''
Json? $converterToJsonName<Json, Value>(
  Value? value,
  Json? Function(Value value) toJson,
) => ${ifNullOrElse('value', 'null', 'toJson(value)')};
''');

      return _nullableJsonConverterLambdaResult(
        converter,
        name: converterToJsonName,
        targetType: targetType,
        expression: expression,
        callback: '${converter.accessString}.toJson',
      );
    }

    return LambdaResult(expression, '${converter.accessString}.toJson');
  }

  @override
  Object? deserialize(
      DartType targetType,
      String expression,
      TypeHelperContextWithConfig context,
      bool defaultProvided,
      ) {
    final converter = _typeConverter(targetType, context);
    if (converter == null) {
      return null;
    }

    if (!converter.jsonType.isNullableType && targetType.isNullableType) {
      const converterFromJsonName = r'_$JsonConverterFromJson';
      context.addMember('''
Value? $converterFromJsonName<Json, Value>(
  Object? json,
  Value? Function(Json json) fromJson,
) => ${ifNullOrElse('json', 'null', 'fromJson(json as Json)')};
''');

      return _nullableJsonConverterLambdaResult(
        converter,
        name: converterFromJsonName,
        targetType: targetType,
        expression: expression,
        callback: '${converter.accessString}.fromJson',
      );
    }

    return LambdaResult(
      expression,
      '${converter.accessString}.fromJson',
      asContent: converter.jsonType,
    );
  }
}

String _nullableJsonConverterLambdaResult(
    _JsonConvertData converter, {
      required String name,
      required DartType targetType,
      required String expression,
      required String callback,
    }) {
  final jsonDisplayString = typeToCode(converter.jsonType);
  final fieldTypeDisplayString = converter.isGeneric ? typeToCode(targetType) : typeToCode(converter.fieldType);

  return '$name<$jsonDisplayString, $fieldTypeDisplayString>('
      '$expression, $callback)';
}

class _JsonConvertData {
  final String accessString;
  final DartType jsonType;
  final DartType fieldType;
  final bool isGeneric;

  _JsonConvertData.className(
      String className,
      String? arguments,
      String accessor,
      this.jsonType,
      this.fieldType,
      )   : accessString = 'const $className${_withAccessor(accessor)}(${arguments ?? ''})',
        isGeneric = false;

  _JsonConvertData.genericClass(
      String className,
      String? arguments,
      String genericTypeArg,
      String accessor,
      this.jsonType,
      this.fieldType,
      )   : accessString = '$className<$genericTypeArg>${_withAccessor(accessor)}(${arguments ?? ''})',
        isGeneric = true;

  _JsonConvertData.propertyAccess(
      this.accessString,
      this.jsonType,
      this.fieldType,
      ) : isGeneric = false;

  static String _withAccessor(String accessor) => accessor.isEmpty ? '' : '.$accessor';
}

/// If there is no converter for the params, return `null`.
///
/// Otherwise, returns `true` if the converter has a null return value.
///
/// Used to make sure we create a smart encoding function.
bool? hasConverterNullEncode(
    DartType targetType,
    TypeHelperContextWithConfig ctx,
    ) {
  final data = _typeConverter(targetType, ctx);

  if (data == null) {
    return null;
  }

  return data.jsonType.isNullableType;
}

_JsonConvertData? _typeConverter(
    DartType targetType,
    TypeHelperContextWithConfig ctx,
    ) {
  List<_ConverterMatch> converterMatches(List<ElementAnnotation> items) => items
      .map(
        (annotation) => _compatibleMatch(
      targetType,
      annotation,
      annotation.computeConstantValue()!,
    ),
  )
      .whereType<_ConverterMatch>()
      .toList();

  var matchingAnnotations = converterMatches(ctx.fieldElement.metadata);

  if (matchingAnnotations.isEmpty) {
    matchingAnnotations = converterMatches(ctx.fieldElement.getter?.metadata ?? []);

    if (matchingAnnotations.isEmpty) {
      matchingAnnotations = converterMatches(ctx.classElement.metadata);

      if (matchingAnnotations.isEmpty) {
        matchingAnnotations = ctx.config.converters.map((e) => _compatibleMatch(targetType, null, e)).whereType<_ConverterMatch>().toList();
      }
    }
  }

  return _typeConverterFrom(matchingAnnotations, targetType);
}

_JsonConvertData? _typeConverterFrom(
    List<_ConverterMatch> matchingAnnotations,
    DartType targetType,
    ) {
  if (matchingAnnotations.isEmpty) {
    return null;
  }

  if (matchingAnnotations.length > 1) {
    final targetTypeCode = typeToCode(targetType);
    throw InvalidGenerationSourceError(
      'Found more than one matching converter for `$targetTypeCode`.',
      element: matchingAnnotations[1].elementAnnotation?.element,
    );
  }

  final match = matchingAnnotations.single;

  final annotationElement = match.elementAnnotation?.element;
  if (annotationElement is PropertyAccessorElement) {
    final enclosing = annotationElement.enclosingElement;

    var accessString = annotationElement.name;

    if (enclosing is ClassElement) {
      accessString = '${enclosing.name}.$accessString';
    }

    return _JsonConvertData.propertyAccess(
      accessString,
      match.jsonType,
      match.fieldType,
    );
  }

  final reviver = ConstantReader(match.annotation).revive();
  // Support generators with constructor arguments
  String? arguments = _argsFromRevivable(reviver);

  if (match.genericTypeArg != null) {
    return _JsonConvertData.genericClass(
      match.annotation.type!.element!.name!,
      arguments,
      match.genericTypeArg!,
      reviver.accessor,
      match.jsonType,
      match.fieldType,
    );
  }

  return _JsonConvertData.className(
    match.annotation.type!.element!.name!,
    arguments,
    reviver.accessor,
    match.jsonType,
    match.fieldType,
  );
}

String? _argsFromRevivable(Revivable reviver) {
  String? arguments, positionalArguments, namedArguments;
  if (reviver.positionalArguments.isNotEmpty) {
    positionalArguments = reviver.positionalArguments.map((DartObject arg) => _argumentValueFromDartObject(arg)).join(', ');
  }
  if (reviver.namedArguments.isNotEmpty) {
    namedArguments = reviver.namedArguments.keys
        .map((String key) {
      dynamic arg = _argumentValueFromDartObject(reviver.namedArguments[key]);
      if (null != arg) return '$key: $arg';
      return null;
    })
        .where(_isNotEmpty)
        .join(', ');
  }
  arguments = <String?>[positionalArguments, namedArguments].where(_isNotEmpty).join(', ');
  return arguments;
}

bool _isNotEmpty(dynamic element) => null != element;

dynamic _argumentValueFromDartObject(DartObject? obj) {
  try {
    if (null != obj) {
      if (obj.type?.isDartCoreString == true) {
        return '\'${obj.toStringValue()}\'';
      } else if (obj.type?.isDartCoreInt == true) {
        return obj.toIntValue();
      } else if (obj.type?.isDartCoreDouble == true) {
        return obj.toDoubleValue();
      } else if (obj.type?.isDartCoreBool == true) {
        return obj.toBoolValue();
      } else if (obj.type?.isDartCoreIterable == true || obj.type?.isDartCoreList == true) {
        return obj.toListValue();
      } else if (obj.type?.isDartCoreMap == true) {
        return obj.toMapValue();
      } else if (obj.type?.isDartCoreSet == true) {
        return obj.toSetValue();
      } else if (obj.type?.isDartCoreSymbol == true) {
        return obj.toSymbolValue();
      } else {
        ExecutableElement? executable = obj.toFunctionValue();
        if (null != executable) {
          return executable.displayName;
        } else if (null != obj.type) {
          String? typeDisplayString = obj.type?.getDisplayString(withNullability: false);
          if (null != typeDisplayString && typeDisplayString != 'Null') {
            final reviver = ConstantReader(obj).revive();
            String? arguments = _argsFromRevivable(reviver);
            return '$typeDisplayString(${arguments ?? ''})';
          }
        }
      }
    }
  } catch (e) {
    print(e);
  }
  return null;
}

class _ConverterMatch {
  final DartObject annotation;
  final DartType fieldType;
  final DartType jsonType;
  final ElementAnnotation? elementAnnotation;
  final String? genericTypeArg;

  _ConverterMatch(
      this.elementAnnotation,
      this.annotation,
      this.jsonType,
      this.genericTypeArg,
      this.fieldType,
      );
}

_ConverterMatch? _compatibleMatch(
    DartType targetType,
    ElementAnnotation? annotation,
    DartObject constantValue,
    ) {
  final converterClassElement = constantValue.type!.element as ClassElement;

  final jsonConverterSuper = converterClassElement.allSupertypes.singleWhereOrNull(
        (e) => _jsonConverterChecker.isExactly(e.element),
  );

  if (jsonConverterSuper == null) {
    return null;
  }

  assert(jsonConverterSuper.element.typeParameters.length == 2);
  assert(jsonConverterSuper.typeArguments.length == 2);

  final fieldType = jsonConverterSuper.typeArguments[0];

  // Allow assigning T to T?
  if (fieldType == targetType || fieldType == targetType.promoteNonNullable()) {
    return _ConverterMatch(
      annotation,
      constantValue,
      jsonConverterSuper.typeArguments[1],
      null,
      fieldType,
    );
  }

  if (fieldType is TypeParameterType && targetType is TypeParameterType) {
    assert(annotation?.element is! PropertyAccessorElement);
    assert(converterClassElement.typeParameters.isNotEmpty);
    if (converterClassElement.typeParameters.length > 1) {
      throw InvalidGenerationSourceError(
          '`JsonConverter` implementations can have no more than one type '
              'argument. `${converterClassElement.name}` has '
              '${converterClassElement.typeParameters.length}.',
          element: converterClassElement);
    }

    return _ConverterMatch(
      annotation,
      constantValue,
      jsonConverterSuper.typeArguments[1],
      '${targetType.element.name}${targetType.isNullableType ? '?' : ''}',
      fieldType,
    );
  }

  return null;
}

const _jsonConverterChecker = TypeChecker.fromRuntime(JsonConverter);
