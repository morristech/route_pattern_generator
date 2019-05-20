import 'package:analyzer/dart/element/element.dart';
import 'package:code_builder/code_builder.dart';
import 'package:recase/recase.dart';
import 'package:source_gen/source_gen.dart';

import 'parsing.dart';

class RouteNaming {
  final ReCase _name;
  RouteNaming(String name) : this._name = ReCase(name);
  String get routeName => "${_name.pascalCase}Route";
  String get argumentName => "${_name.pascalCase}RouteArguments";
}

class RoutesBuilder {
  Class build(List<AnnotatedElement> elements) {
    final builder = ClassBuilder()
      ..name = "Routes"
      ..abstract = true;

    builder.fields.add(Field((f) => f
      ..name = "_router"
      ..modifier = FieldModifier.constant
      ..static = true
      ..assignment = Code(
          "Router(routes: [${elements.map((e) => e.element.name).join(",")}])")));

    builder.methods.add(Method((b) => b
      ..name = "match"
      ..static = true
      ..returns = refer("MatchResult")
      ..body = Code("return _router.match(path);")
      ..requiredParameters.add(Parameter((p) => p
        ..name = 'path'
        ..type = refer("String")))));

    elements.forEach((e) => builder.fields.add(Field((b) => b
      ..name = e.element.name
      ..modifier = FieldModifier.constant
      ..static = true
      ..assignment = Code(RouteNaming(e.element.name).routeName + '()'))));

    return builder.build();
  }
}

class RouteBuilder {
  Method _createMatch(ParsedPattern pattern, RouteNaming naming) {
    final body = StringBuffer();

    final conditions = ["parsed.requiredCount != ${pattern.segments.length}"]
      ..addAll(pattern.segments
          .where((x) => x is ConstantSegment)
          .cast<ConstantSegment>()
          .map((x) => 'parsed.required(${x.index}) != "${x.value}"'));

    body.write("final parsed = ParsedRoute.fromPath(path);");
    body.write(
        "if (${conditions.join(" || ")}) return MatchResult.fail(this);");
    body.write("return MatchResult.success(this,${naming.argumentName}(");
    pattern.segments
        .where((x) => x is DynamicSegment)
        .cast<DynamicSegment>()
        .forEach((x) => x.type == "String"
            ? body.write("${x.name}: parsed.required(${x.index}),")
            : body.write(
                "${x.name}: ${x.type}.parse(parsed.required(${x.index})),"));

    pattern.query.forEach((x) => x.type == "String"
        ? body.write('${x.name}: parsed.optional("${x.name}"),')
        : body.write('${x.name}: ${x.type}.parse(parsed.optional("${x.name}")),'));

    body.write("));");

    return Method((m) => m
      ..name = "match"
      ..annotations.add(CodeExpression(Code("override")))
      ..returns = refer("MatchResult<${naming.argumentName}>")
      ..requiredParameters.add(Parameter((p) => p
        ..name = "path"
        ..type = refer("String")))
      ..body = Code(body.toString()));
  }

  Method _createBuild(ParsedPattern pattern, RouteNaming naming) {
    final body = StringBuffer();

    body.write("return Route.buildPath(");

    if (pattern.segments.isNotEmpty) {
      final args = pattern.segments
          .map((s) => s is ConstantSegment
              ? '"${s.value}"'
              : ("arguments." + (s as DynamicSegment).name) + ".toString()")
          .join(",");
      body.write("[$args]");
    }

    if (pattern.query.isNotEmpty) {
      if (pattern.segments.isEmpty) body.write("[]");
      final args = pattern.query.map((n) => '"${n.name}": arguments.${n.name}.toString()').join(",");
      body.write(",{$args}");
    }

    body.write(");");

    return Method((m) => m
      ..name = "build"
      ..annotations.add(CodeExpression(Code("override")))
      ..returns = refer("String")
      ..requiredParameters.add(Parameter((p) => p
        ..name = "arguments"
        ..type = refer(naming.argumentName)))
      ..body = Code(body.toString()));
  }

  Class build(String name, ParsedPattern pattern) {
    final naming = RouteNaming(name);
    final builder = ClassBuilder()
      ..name = naming.routeName
      ..extend = refer("Route<${naming.argumentName}>");

    builder.constructors.add(Constructor((b) => b..constant = true));

    builder.methods.add(_createMatch(pattern, naming));
    builder.methods.add(_createBuild(pattern, naming));

    return builder.build();
  }
}

class ArgumentBuilder {
  Class build(String name, ParsedPattern pattern) {
    final naming = RouteNaming(name);
    final builder = ClassBuilder()..name = naming.argumentName;

    final constructor = ConstructorBuilder();
    pattern.segments
        .where((x) => x is DynamicSegment)
        .cast<DynamicSegment>()
        .forEach((x) => _addField(x, true, builder, constructor));
    pattern.query
        .forEach((name) => _addField(name, false, builder, constructor));

    builder.constructors.add(constructor.build());

    return builder.build();
  }

  void _addField(TypedParameter typed, bool isRequired, ClassBuilder builder,
      ConstructorBuilder constructor) {
    builder.fields.add(Field((b) => b
      ..name = typed.name
      ..type = refer(typed.type)
      ..modifier = FieldModifier.final$));

    final parameter = ParameterBuilder()
      ..name = typed.name
      ..toThis = true
      ..named = true;

    if (isRequired) {
      parameter.annotations.add(CodeExpression(Code("required")));
    }
    constructor.optionalParameters.add(parameter.build());
  }
}
