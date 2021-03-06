// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * A function element that represents a closure call. The signature is copied
 * from the given element.
 */
class ClosureInvocationElement extends FunctionElement {
  ClosureInvocationElement(SourceString name,
                           FunctionElement other)
      : super.from(name, other, other.enclosingElement),
        methodElement = other;

  isInstanceMember() => true;

  Element getOutermostEnclosingMemberOrTopLevel() => methodElement;

  /**
   * The [member] this invocation refers to.
   */
  Element methodElement;
}

/**
 * Generates the code for all used classes in the program. Static fields (even
 * in classes) are ignored, since they can be treated as non-class elements.
 *
 * The code for the containing (used) methods must exist in the [:universe:].
 */
class CodeEmitterTask extends CompilerTask {
  bool needsInheritFunction = false;
  bool needsDefineClass = false;
  bool needsClosureClass = false;
  bool needsLazyInitializer = false;
  final Namer namer;
  ConstantEmitter constantEmitter;
  NativeEmitter nativeEmitter;
  CodeBuffer boundClosureBuffer;
  CodeBuffer mainBuffer;
  /** Shorter access to [isolatePropertiesName]. Both here in the code, as
      well as in the generated code. */
  String isolateProperties;
  String classesCollector;
  final Map<int, String> boundClosureCache;
  Set<ClassElement> checkedClasses;

  final bool generateSourceMap;

  CodeEmitterTask(Compiler compiler, Namer namer,
                  [bool generateSourceMap = false])
      : boundClosureBuffer = new CodeBuffer(),
        mainBuffer = new CodeBuffer(),
        this.namer = namer,
        boundClosureCache = new Map<int, String>(),
        generateSourceMap = generateSourceMap,
        constantEmitter = new ConstantEmitter(compiler, namer),
        super(compiler) {
    nativeEmitter = new NativeEmitter(this);
  }

  void computeRequiredTypeChecks() {
    assert(checkedClasses == null);
    checkedClasses = new Set<ClassElement>();
    compiler.codegenWorld.isChecks.forEach((DartType t) {
      if (t is InterfaceType) checkedClasses.add(t.element);
    });
  }

  void writeConstantToBuffer(Constant value, CodeBuffer buffer,
                             [emitCanonicalVersion = true]) {
    if (emitCanonicalVersion) {
      constantEmitter.emitCanonicalVersionOfConstant(value, buffer);
    } else {
      constantEmitter.emitJavaScriptCodeForConstant(value, buffer);
    }
  }

  String get name => 'CodeEmitter';

  String get defineClassName
      => '${namer.ISOLATE}.\$defineClass';
  String get finishClassesName
      => '${namer.ISOLATE}.\$finishClasses';
  String get finishIsolateConstructorName
      => '${namer.ISOLATE}.\$finishIsolateConstructor';
  String get pendingClassesName
      => '${namer.ISOLATE}.\$pendingClasses';
  String get isolatePropertiesName
      => '${namer.ISOLATE}.${namer.ISOLATE_PROPERTIES}';
  String get supportsProtoName
      => 'supportsProto';
  String get lazyInitializerName
      => '${namer.ISOLATE}.\$lazy';

  final String GETTER_SUFFIX = "?";
  final String SETTER_SUFFIX = "!";
  final String GETTER_SETTER_SUFFIX = "=";

  String get generateGetterSetterFunction {
    return """
  function(field, prototype) {
    var len = field.length;
    var lastChar = field[len - 1];
    var needsGetter = lastChar == '$GETTER_SUFFIX' || lastChar == '$GETTER_SETTER_SUFFIX';
    var needsSetter = lastChar == '$SETTER_SUFFIX' || lastChar == '$GETTER_SETTER_SUFFIX';
    if (needsGetter || needsSetter) field = field.substring(0, len - 1);
    if (needsGetter) {
      var getterString = "return this." + field + ";";
  """
  /* The supportsProtoCheck below depends on the getter/setter convention.
         When changing here, update the protoCheck too. */
  """
      prototype["get\$" + field] = new Function(getterString);
    }
    if (needsSetter) {
      var setterString = "this." + field + " = v;";
      prototype["set\$" + field] = new Function("v", setterString);
    }
    return field;
  }""";
  }

  String get defineClassFunction {
    // First the class name, then the super class name, followed by the fields
    // (in an array) and the members (inside an Object literal).
    // The caller can also pass in the constructor as a function if needed.
    //
    // Example:
    // defineClass("A", "B", ["x", "y"], {
    //  foo$1: function(y) {
    //   print(this.x + y);
    //  },
    //  bar$2: function(t, v) {
    //   this.x = t - v;
    //  },
    // });
    return """
function(cls, fields, prototype) {
  var generateGetterSetter = $generateGetterSetterFunction;
  var constructor;
  if (typeof fields == 'function') {
    constructor = fields;
  } else {
    var str = "function " + cls + "(";
    var body = "";
    for (var i = 0; i < fields.length; i++) {
      if (i != 0) str += ", ";
      var field = fields[i];
      field = generateGetterSetter(field, prototype);
      str += field;
      body += "this." + field + " = " + field + ";\\n";
    }
    str += ") {" + body + "}\\n";
    str += "return " + cls + ";";
    constructor = new Function(str)();
  }
  constructor.prototype = prototype;
  return constructor;
}""";
  }

  /** Needs defineClass to be defined. */
  String get protoSupportCheck {
    // On Firefox and Webkit browsers we can manipulate the __proto__
    // directly. Opera claims to have __proto__ support, but it is buggy.
    // So we have to do more checks.
    // If the browser does not support __proto__ we need to instantiate an
    // object with the correct (internal) prototype set up correctly, and then
    // copy the members.

    return '''
var $supportsProtoName = false;
var tmp = $defineClassName('c', ['f?'], {}).prototype;
if (tmp.__proto__) {
  tmp.__proto__ = {};
  if (typeof tmp.get\$f !== "undefined") $supportsProtoName = true;
}
''';
  }

  String get finishClassesFunction {
    // 'defineClass' does not require the classes to be constructed in order.
    // Classes are initially just stored in the 'pendingClasses' field.
    // 'finishClasses' takes all pending classes and sets up the prototype.
    // Once set up, the constructors prototype field satisfy:
    //  - it contains all (local) members.
    //  - its internal prototype (__proto__) points to the superclass'
    //    prototype field.
    //  - the prototype's constructor field points to the JavaScript
    //    constructor.
    // For engines where we have access to the '__proto__' we can manipulate
    // the object literal directly. For other engines we have to create a new
    // object and copy over the members.
    return '''
function(collectedClasses) {
  var hasOwnProperty = Object.prototype.hasOwnProperty;
  for (var cls in collectedClasses) {
    if (hasOwnProperty.call(collectedClasses, cls)) {
      var desc = collectedClasses[cls];
      $isolatePropertiesName[cls] = $defineClassName(cls, desc[''], desc);
      if (desc['super'] !== "") $pendingClassesName[cls] = desc['super'];
    }
  }
  var pendingClasses = $pendingClassesName;
'''/* FinishClasses can be called multiple times. This means that we need to
      clear the pendingClasses property. */'''
  $pendingClassesName = {};
  var finishedClasses = {};
  function finishClass(cls) {
'''/* Opera does not support 'getOwnPropertyNames'. Therefore we use
      hasOwnProperty instead. */'''
    var hasOwnProperty = Object.prototype.hasOwnProperty;
    if (hasOwnProperty.call(finishedClasses, cls)) return;
    finishedClasses[cls] = true;
    var superclass = pendingClasses[cls];
'''/* The superclass is only false (empty string) for Dart's Object class. */'''
    if (!superclass) return;
    finishClass(superclass);
    var constructor = $isolatePropertiesName[cls];
    var superConstructor = $isolatePropertiesName[superclass];
    var prototype = constructor.prototype;
    if ($supportsProtoName) {
      prototype.__proto__ = superConstructor.prototype;
      prototype.constructor = constructor;
    } else {
      function tmp() {};
      tmp.prototype = superConstructor.prototype;
      var newPrototype = new tmp();
      constructor.prototype = newPrototype;
      newPrototype.constructor = constructor;
      for (var member in prototype) {
        if (member == '' || member == 'super') continue;
        if (hasOwnProperty.call(prototype, member)) {
          newPrototype[member] = prototype[member];
        }
      }
    }
  }
  for (var cls in pendingClasses) finishClass(cls);
}''';
  }

  String get finishIsolateConstructorFunction {
    String isolate = namer.ISOLATE;
    // We replace the old Isolate function with a new one that initializes
    // all its field with the initial (and often final) value of all globals.
    // This has two advantages:
    //   1. the properties are in the object itself (thus avoiding to go through
    //      the prototype when looking up globals.
    //   2. a new isolate goes through a (usually well optimized) constructor
    //      function of the form: "function() { this.x = ...; this.y = ...; }".
    //
    // Example: If [isolateProperties] is an object containing: x = 3 and
    // A = function A() { /* constructor of class A. */ }, then we generate:
    // str = "{
    //   var isolateProperties = Isolate.$isolateProperties;
    //   this.x = isolateProperties.x;
    //   this.A = isolateProperties.A;
    // }";
    // which is then dynamically evaluated:
    //   var newIsolate = new Function(str);
    //
    // We also copy over old values like the prototype, and the
    // isolateProperties themselves.
    return """function(oldIsolate) {
  var isolateProperties = oldIsolate.${namer.ISOLATE_PROPERTIES};
  var isolatePrototype = oldIsolate.prototype;
  var str = "{\\n";
  str += "var properties = $isolate.${namer.ISOLATE_PROPERTIES};\\n";
  for (var staticName in isolateProperties) {
    if (Object.prototype.hasOwnProperty.call(isolateProperties, staticName)) {
      str += "this." + staticName + "= properties." + staticName + ";\\n";
    }
  }
  str += "}\\n";
  var newIsolate = new Function(str);
  newIsolate.prototype = isolatePrototype;
  isolatePrototype.constructor = newIsolate;
  newIsolate.${namer.ISOLATE_PROPERTIES} = isolateProperties;
  return newIsolate;
}""";
  }

  String get lazyInitializerFunction {
    String isolate = namer.CURRENT_ISOLATE;
    JavaScriptBackend backend = compiler.backend;
    String cyclicThrow = namer.isolateAccess(backend.cyclicThrowHelper);
    return """
function(prototype, staticName, fieldName, getterName, lazyValue) {
  var sentinelUndefined = {};
  var sentinelInProgress = {};
  prototype[fieldName] = sentinelUndefined;
  var getter = new Function("{ return $isolate." + fieldName + ";}");
  prototype[getterName] = function() {
    var result = $isolate[fieldName];
    try {
      if (result === sentinelUndefined) {
        $isolate[fieldName] = sentinelInProgress;
        try {
          result = $isolate[fieldName] = lazyValue();
        } catch (e) {
          if ($isolate[fieldName] === sentinelInProgress) {
            $isolate[fieldName] = null;
          }
          throw e;
        }
      } else if (result === sentinelInProgress) {
        $cyclicThrow(staticName);
      }
      return result;
    } finally {
      $isolate[getterName] = getter;
    }
  };
}""";
  }

  void addDefineClassAndFinishClassFunctionsIfNecessary(CodeBuffer buffer) {
    if (needsDefineClass) {
      buffer.add("$defineClassName = $defineClassFunction;\n");
      buffer.add(protoSupportCheck);
      buffer.add("$pendingClassesName = {};\n");
      buffer.add("$finishClassesName = $finishClassesFunction;\n");
    }
  }

  void addLazyInitializerFunctionIfNecessary(CodeBuffer buffer) {
    if (needsLazyInitializer) {
      buffer.add("$lazyInitializerName = $lazyInitializerFunction;\n");
    }
  }

  void emitFinishIsolateConstructor(CodeBuffer buffer) {
    String name = finishIsolateConstructorName;
    String value = finishIsolateConstructorFunction;
    buffer.add("$name = $value;\n");
  }

  void emitFinishIsolateConstructorInvocation(CodeBuffer buffer) {
    String isolate = namer.ISOLATE;
    buffer.add("$isolate = $finishIsolateConstructorName($isolate);\n");
  }

  /**
   * Generate stubs to handle invocation of methods with optional
   * arguments.
   *
   * A method like [: foo([x]) :] may be invoked by the following
   * calls: [: foo(), foo(1), foo(x: 1) :]. See the sources of this
   * function for detailed examples.
   */
  void addParameterStub(FunctionElement member,
                        Selector selector,
                        DefineMemberFunction defineInstanceMember,
                        Set<String> alreadyGenerated) {
    FunctionSignature parameters = member.computeSignature(compiler);
    int positionalArgumentCount = selector.positionalArgumentCount;
    if (positionalArgumentCount == parameters.parameterCount) {
      assert(selector.namedArgumentCount == 0);
      return;
    }
    if (parameters.optionalParametersAreNamed
        && selector.namedArgumentCount == parameters.optionalParameterCount) {
      // If the selector has the same number of named arguments as
      // the element, we don't need to add a stub. The call site will
      // hit the method directly.
      return;
    }
    ConstantHandler handler = compiler.constantHandler;
    List<SourceString> names = selector.getOrderedNamedArguments();

    String invocationName =
        namer.instanceMethodInvocationName(member.getLibrary(), member.name,
                                           selector);
    if (alreadyGenerated.contains(invocationName)) return;
    alreadyGenerated.add(invocationName);
    CodeBuffer buffer = new CodeBuffer();
    buffer.add('function(');

    // The parameters that this stub takes.
    List<String> parametersBuffer = new List<String>(selector.argumentCount);
    // The arguments that will be passed to the real method.
    List<String> argumentsBuffer = new List<String>(parameters.parameterCount);

    int count = 0;
    int indexOfLastOptionalArgumentInParameters = positionalArgumentCount - 1;
    TreeElements elements =
        compiler.enqueuer.resolution.getCachedElements(member);

    parameters.orderedForEachParameter((Element element) {
      String jsName = JsNames.getValid(element.name.slowToString());
      if (count < positionalArgumentCount) {
        parametersBuffer[count] = jsName;
        argumentsBuffer[count] = jsName;
      } else {
        int index = names.indexOf(element.name);
        if (index != -1) {
          indexOfLastOptionalArgumentInParameters = count;
          // The order of the named arguments is not the same as the
          // one in the real method (which is in Dart source order).
          argumentsBuffer[count] = jsName;
          parametersBuffer[selector.positionalArgumentCount + index] = jsName;
        // Note that [elements] may be null for a synthetized [member].
        } else if (elements != null && elements.isParameterChecked(element)) {
          CodeBuffer argumentBuffer = new CodeBuffer();
          writeConstantToBuffer(SentinelConstant.SENTINEL, argumentBuffer);
          argumentsBuffer[count] = argumentBuffer.toString();
        } else {
          Constant value = handler.initialVariableValues[element];
          if (value == null) {
            argumentsBuffer[count] = NullConstant.JsNull;
          } else {
            if (!value.isNull()) {
              // If the value is the null constant, we should not pass it
              // down to the native method.
              indexOfLastOptionalArgumentInParameters = count;
            }
            CodeBuffer argumentBuffer = new CodeBuffer();
            writeConstantToBuffer(value, argumentBuffer);
            argumentsBuffer[count] = argumentBuffer.toString();
          }
        }
      }
      count++;
    });
    String parametersString = Strings.join(parametersBuffer, ",");
    buffer.add('$parametersString) {\n');

    if (member.isNative()) {
      nativeEmitter.generateParameterStub(
          member, invocationName, parametersString, argumentsBuffer,
          indexOfLastOptionalArgumentInParameters, buffer);
    } else {
      String arguments = Strings.join(argumentsBuffer, ",");
      buffer.add('  return this.${namer.getName(member)}($arguments)');
    }
    buffer.add('\n}');
    defineInstanceMember(invocationName, buffer);
  }

  void addParameterStubs(FunctionElement member,
                         DefineMemberFunction defineInstanceMember) {
    // TODO(5074): Update this comment once we remove support for
    // the deprecated parameter specification.
    // We fill the lists depending on the selector. For example,
    // take method foo:
    //    foo(a, b, [c, d]);
    //
    // We may have multiple ways of calling foo:
    // (1) foo(1, 2, 3, 4)
    // (2) foo(1, 2);
    // (3) foo(1, 2, 3);
    // (4) foo(1, 2, c: 3);
    // (5) foo(1, 2, d: 4);
    // (6) foo(1, 2, c: 3, d: 4);
    // (7) foo(1, 2, d: 4, c: 3);
    //
    // What we generate at the call sites are:
    // (1) foo$4(1, 2, 3, 4)
    // (2) foo$2(1, 2);
    // (3) foo$3(1, 2, 3);
    // (4) foo$3$c(1, 2, 3);
    // (5) foo$3$d(1, 2, 4);
    // (6) foo$4$c$d(1, 2, 3, 4);
    // (7) foo$4$c$d(1, 2, 3, 4);
    //
    // The stubs we generate are (expressed in Dart):
    // (1) No stub generated, call is direct.
    // (2) foo$2(a, b) => foo$4(a, b, null, null)
    // (3) foo$3(a, b, c) => foo$4(a, b, c, null)
    // (4) foo$3$c(a, b, c) => foo$4(a, b, c, null);
    // (5) foo$3$d(a, b, d) => foo$4(a, b, null, d);
    // (6) foo$4$c$d(a, b, c, d) => foo$4(a, b, c, d);
    // (7) Same as (5).
    //
    // We need to generate a stub for (5) because the order of the
    // stub arguments and the real method may be different.

    // Keep a cache of which stubs have already been generated, to
    // avoid duplicates. Note that even if selectors are
    // canonicalized, we would still need this cache: a typed selector
    // on A and a typed selector on B could yield the same stub.
    Set<String> generatedStubNames = new Set<String>();
    if (compiler.enabledFunctionApply
        && member.name == Namer.CLOSURE_INVOCATION_NAME) {
      // If [Function.apply] is called, we pessimistically compile all
      // possible stubs for this closure.
      // TODO(5074): This functionality only supports the new
      // parameter specification, and this comment should be removed
      // once the old specification is not supported.
      FunctionSignature signature = member.computeSignature(compiler);
      Set<Selector> selectors = signature.optionalParametersAreNamed
          ? computeNamedSelectors(signature, member)
          : computeOptionalSelectors(signature, member);
      for (Selector selector in selectors) {
        addParameterStub(
            member, selector, defineInstanceMember, generatedStubNames);
      }
    } else {
      Set<Selector> selectors = compiler.codegenWorld.invokedNames[member.name];
      if (selectors == null) return;
      for (Selector selector in selectors) {
        if (!selector.applies(member, compiler)) continue;
        addParameterStub(
            member, selector, defineInstanceMember, generatedStubNames);
      }
    }
  }

  /**
   * Compute the set of possible selectors in the presence of named
   * parameters.
   */
  Set<Selector> computeNamedSelectors(FunctionSignature signature,
                                      FunctionElement element) {
    Set<Selector> selectors = new Set<Selector>();
    // Add the selector that does not have any optional argument.
    selectors.add(new Selector(SelectorKind.CALL,
                               element.name,
                               element.getLibrary(),
                               signature.requiredParameterCount,
                               <SourceString>[]));

    // For each optional parameter, we iterator over the set of
    // already computed selectors and create new selectors with that
    // parameter now being passed.
    signature.forEachOptionalParameter((Element element) {
      Set<Selector> newSet = new Set<Selector>();
      selectors.forEach((Selector other) {
        List<SourceString> namedArguments = [element.name];
        namedArguments.addAll(other.namedArguments);
        newSet.add(new Selector(other.kind,
                                other.name,
                                other.library,
                                other.argumentCount + 1,
                                namedArguments));
      });
      selectors.addAll(newSet);
    });
    return selectors;
  }

  /**
   * Compute the set of possible selectors in the presence of optional
   * non-named parameters.
   */
  Set<Selector> computeOptionalSelectors(FunctionSignature signature,
                                         FunctionElement element) {
    Set<Selector> selectors = new Set<Selector>();
    // Add the selector that does not have any optional argument.
    selectors.add(new Selector(SelectorKind.CALL,
                               element.name,
                               element.getLibrary(),
                               signature.requiredParameterCount,
                               <SourceString>[]));

    // For each optional parameter, we increment the number of passed
    // argument.
    for (int i = 1; i <= signature.optionalParameterCount; i++) {
      selectors.add(new Selector(SelectorKind.CALL,
                                 element.name,
                                 element.getLibrary(),
                                 signature.requiredParameterCount + i,
                                 <SourceString>[]));
    }
    return selectors;
  }

  bool instanceFieldNeedsGetter(Element member) {
    assert(member.isField());
    return compiler.codegenWorld.hasInvokedGetter(member, compiler);
  }

  bool instanceFieldNeedsSetter(Element member) {
    assert(member.isField());
    return (!member.modifiers.isFinalOrConst())
        && compiler.codegenWorld.hasInvokedSetter(member, compiler);
  }

  String compiledFieldName(Element member) {
    assert(member.isField());
    return member.isNative()
        ? member.name.slowToString()
        : namer.getName(member);
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [member] must be a declaration element.
   */
  void addInstanceMember(Element member,
                         DefineMemberFunction defineInstanceMember) {
    assert(invariant(member, member.isDeclaration));
    // TODO(floitsch): we don't need to deal with members of
    // uninstantiated classes, that have been overwritten by subclasses.

    if (member.isFunction()
        || member.isGenerativeConstructorBody()
        || member.isGetter()
        || member.isSetter()) {
      if (member.modifiers.isAbstract()) return;
      CodeBuffer codeBuffer = compiler.codegenWorld.generatedCode[member];
      if (codeBuffer == null) return;
      defineInstanceMember(namer.getName(member), codeBuffer);
      codeBuffer = compiler.codegenWorld.generatedBailoutCode[member];
      if (codeBuffer !== null) {
        defineInstanceMember(namer.getBailoutName(member), codeBuffer);
      }
      FunctionElement function = member;
      FunctionSignature parameters = function.computeSignature(compiler);
      if (!parameters.optionalParameters.isEmpty()) {
        addParameterStubs(member, defineInstanceMember);
      }
    } else if (!member.isField()) {
      compiler.internalError('unexpected kind: "${member.kind}"',
                             element: member);
    }
    emitExtraAccessors(member, defineInstanceMember);
  }

  String generateCheckedSetter(Element member, String fieldName) {
    DartType type = member.computeType(compiler);
    if (type.element.isTypeVariable()
        || type.element == compiler.dynamicClass
        || type.element == compiler.objectClass) {
      // TODO(ngeoffray): Support type checks on type parameters.
      return null;
    } else {
      SourceString helper = compiler.backend.getCheckedModeHelper(type);
      FunctionElement helperElement = compiler.findHelper(helper);
      String helperName = namer.isolateAccess(helperElement);
      String additionalArgument = '';
      if (helperElement.computeSignature(compiler).parameterCount != 1) {
        additionalArgument = ", '${namer.operatorIs(type.element)}'";
      }
      return " set\$$fieldName: function(v) { "
          "this.$fieldName = $helperName(v$additionalArgument); }";
    }
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [classElement] must be a declaration element.
   */
  List<String> emitClassFields(ClassElement classElement, CodeBuffer buffer) {
    assert(invariant(classElement, classElement.isDeclaration));
    // If the class is never instantiated we still need to set it up for
    // inheritance purposes, but we can simplify its JavaScript constructor.
    bool isInstantiated =
        compiler.codegenWorld.instantiatedClasses.contains(classElement);
    List<String> checkedSetters = <String>[];

    bool isFirstField = true;
    void addField(ClassElement enclosingClass, Element member) {
      assert(!member.isNative());
      assert(invariant(classElement, member.isDeclaration));

      LibraryElement library = member.getLibrary();
      SourceString name = member.name;
      bool isPrivate = name.isPrivate();
      // See if we can dynamically create getters and setters.
      // We can only generate getters and setters for [classElement] since
      // the fields of super classes could be overwritten with getters or
      // setters.
      bool needsDynamicGetter = false;
      bool needsDynamicSetter = false;
      // We need to name shadowed fields differently, so they don't clash with
      // the non-shadowed field.
      bool isShadowed = false;
      if (enclosingClass === classElement) {
        needsDynamicGetter = instanceFieldNeedsGetter(member);
        needsDynamicSetter = instanceFieldNeedsSetter(member);
      } else {
        isShadowed = classElement.isShadowedByField(member);
      }

      if ((isInstantiated && !enclosingClass.isNative())
          || needsDynamicGetter
          || needsDynamicSetter) {
        if (isFirstField) {
          isFirstField = false;
        } else {
          buffer.add(", ");
        }
        String fieldName = isShadowed
            ? namer.shadowedFieldName(member)
            : namer.getName(member);
        if (needsDynamicSetter && compiler.enableTypeAssertions) {
          String setter = generateCheckedSetter(member, fieldName);
          if (setter != null) {
            needsDynamicSetter = false;
            checkedSetters.add(setter);
          }
        }
        // Getters and setters with suffixes will be generated dynamically.
        buffer.add('"$fieldName');
        if (needsDynamicGetter || needsDynamicSetter) {
          if (needsDynamicGetter && needsDynamicSetter) {
            buffer.add(GETTER_SETTER_SUFFIX);
          } else if (needsDynamicGetter) {
            buffer.add(GETTER_SUFFIX);
          } else {
            buffer.add(SETTER_SUFFIX);
          }
        }
        buffer.add('"');
      }
    }

    // If a class is not instantiated then we add the field just so we can
    // generate the field getter/setter dynamically. Since this is only
    // allowed on fields that are in [classElement] we don't need to visit
    // superclasses for non-instantiated classes.
    classElement.implementation.forEachInstanceField(
        addField,
        includeBackendMembers: true,
        includeSuperMembers: isInstantiated && !classElement.isNative());
    return checkedSetters;
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [classElement] must be a declaration element.
   */
  void emitInstanceMembers(ClassElement classElement,
                           CodeBuffer buffer,
                           bool needsLeadingComma) {
    assert(invariant(classElement, classElement.isDeclaration));
    bool needsComma = needsLeadingComma;
    void defineInstanceMember(String name, CodeBuffer memberBuffer) {
      if (needsComma) buffer.add(',');
      needsComma = true;
      buffer.add('\n');
      buffer.add(' $name: ');
      buffer.add(memberBuffer);
    }

    classElement.implementation.forEachMember(includeBackendMembers: true,
        f: (ClassElement enclosing, Element member) {
      assert(invariant(classElement, member.isDeclaration));
      if (member.isInstanceMember()) {
        addInstanceMember(member, defineInstanceMember);
      }
    });

    generateIsTestsOn(classElement, (ClassElement other) {
      String code;
      if (other.isObject(compiler)) return;
      if (nativeEmitter.requiresNativeIsCheck(other)) {
        code = 'function() { return true; }';
      } else {
        code = 'true';
      }
      CodeBuffer typeTestBuffer = new CodeBuffer();
      typeTestBuffer.add(code);
      defineInstanceMember(namer.operatorIs(other), typeTestBuffer);
    });

    if (classElement === compiler.objectClass && compiler.enabledNoSuchMethod) {
      // Emit the noSuchMethod handlers on the Object prototype now,
      // so that the code in the dynamicFunction helper can find
      // them. Note that this helper is invoked before analyzing the
      // full JS script.
      if (!nativeEmitter.handleNoSuchMethod) {
        emitNoSuchMethodHandlers(defineInstanceMember);
      }
    }
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [classElement] must be a declaration element.
   */
  void generateClass(ClassElement classElement, CodeBuffer buffer) {
    assert(invariant(classElement, classElement.isDeclaration));
    if (classElement.isNative()) {
      nativeEmitter.generateNativeClass(classElement);
      return;
    } else {
      // TODO(ngeoffray): Instead of switching between buffer, we
      // should create code sections, and decide where to emit them at
      // the end.
      buffer = mainBuffer;
    }

    needsDefineClass = true;
    String className = namer.getName(classElement);
    ClassElement superclass = classElement.superclass;
    String superName = "";
    if (superclass !== null) {
      superName = namer.getName(superclass);
    }
    String constructorName = namer.safeName(classElement.name.slowToString());

    buffer.add('$classesCollector.$className = {"":\n');
    buffer.add(' [');
    List<String> checkedSetters = emitClassFields(classElement, buffer);
    buffer.add('],\n');
    // TODO(floitsch): the emitInstanceMember should simply always emit a ',\n'.
    // That does currently not work because the native classes have a different
    // syntax.
    buffer.add(' "super": "$superName"');
    if (!checkedSetters.isEmpty()) {
      buffer.add(',\n');
      buffer.add('${Strings.join(checkedSetters, ",\n")}');
    }
    emitInstanceMembers(classElement, buffer, true);
    buffer.add('\n};\n\n');
  }

  /**
   * Generate "is tests" for [cls]: itself, and the "is tests" for the
   * classes it implements. We don't need to add the "is tests" of the
   * super class because they will be inherited at runtime.
   */
  void generateIsTestsOn(ClassElement cls,
                         void emitIsTest(ClassElement element)) {
    if (checkedClasses.contains(cls)) {
      emitIsTest(cls);
    }
    Set<Element> generated = new Set<Element>();
    for (DartType interfaceType in cls.interfaces) {
      generateInterfacesIsTests(interfaceType.element, emitIsTest, generated);
    }
  }

  /**
   * Generate "is tests" where [cls] is being implemented.
   */
  void generateInterfacesIsTests(ClassElement cls,
                                 void emitIsTest(ClassElement element),
                                 Set<Element> alreadyGenerated) {
    void tryEmitTest(ClassElement cls) {
      if (!alreadyGenerated.contains(cls) && checkedClasses.contains(cls)) {
        alreadyGenerated.add(cls);
        emitIsTest(cls);
      }
    };

    tryEmitTest(cls);

    for (DartType interfaceType in cls.interfaces) {
      Element element = interfaceType.element;
      tryEmitTest(element);
      generateInterfacesIsTests(element, emitIsTest, alreadyGenerated);
    }

    // We need to also emit "is checks" for the superclass and its supertypes.
    ClassElement superclass = cls.superclass;
    if (superclass != null) {
      tryEmitTest(superclass);
      generateInterfacesIsTests(superclass, emitIsTest, alreadyGenerated);
    }
  }

  void emitClasses(CodeBuffer buffer) {
    // Compute the required type checks to know which classes need a
    // 'is$' method.
    computeRequiredTypeChecks();
    Set<ClassElement> instantiatedClasses =
        compiler.codegenWorld.instantiatedClasses;
    Set<ClassElement> neededClasses =
        new Set<ClassElement>.from(instantiatedClasses);
    for (ClassElement element in instantiatedClasses) {
      for (ClassElement superclass = element.superclass;
           superclass !== null;
           superclass = superclass.superclass) {
        if (neededClasses.contains(superclass)) break;
        neededClasses.add(superclass);
      }
    }
    List<ClassElement> sortedClasses =
        new List<ClassElement>.from(neededClasses);
    sortedClasses.sort((ClassElement class1, ClassElement class2) {
      // We sort by the ids of the classes. There is no guarantee that these
      // ids are meaningful (or even deterministic), but in the current
      // implementation they are increasing within a source file.
      return class1.id - class2.id;
    });

    // If we need noSuchMethod support, we run through all needed
    // classes to figure out if we need the support on any native
    // class. If so, we let the native emitter deal with it.
    if (compiler.enabledNoSuchMethod) {
      SourceString noSuchMethodName = Compiler.NO_SUCH_METHOD;
      Selector noSuchMethodSelector = new Selector.noSuchMethod();
      for (ClassElement element in sortedClasses) {
        if (!element.isNative()) continue;
        Element member = element.lookupLocalMember(noSuchMethodName);
        if (member === null) continue;
        if (noSuchMethodSelector.applies(member, compiler)) {
          nativeEmitter.handleNoSuchMethod = true;
          break;
        }
      }
    }

    for (ClassElement element in sortedClasses) {
      generateClass(element, buffer);
    }

    // The closure class could have become necessary because of the generation
    // of stubs.
    ClassElement closureClass = compiler.closureClass;
    if (needsClosureClass && !instantiatedClasses.contains(closureClass)) {
      generateClass(closureClass, buffer);
    }
  }

  void emitFinishClassesInvocationIfNecessary(CodeBuffer buffer) {
    if (needsDefineClass) {
      buffer.add("$finishClassesName($classesCollector);\n");
      // Reset the map.
      buffer.add("$classesCollector = {};\n");
    }
  }

  void emitStaticFunctionWithNamer(CodeBuffer buffer,
                                   Element element,
                                   CodeBuffer functionBuffer,
                                   String functionNamer(Element element)) {
    String functionName = functionNamer(element);
    buffer.add('$isolateProperties.$functionName = ');
    buffer.add(functionBuffer);
    buffer.add(';\n\n');
  }
  void emitStaticFunctionsWithNamer(CodeBuffer buffer,
                                    Map<Element, CodeBuffer> generatedCode,
                                    String functionNamer(Element element)) {
    generatedCode.forEach((Element element, CodeBuffer functionBuffer) {
      if (!element.isInstanceMember() && !element.isField()) {
        emitStaticFunctionWithNamer(
            buffer, element, functionBuffer,functionNamer);
      }
    });
  }

  void emitStaticFunctions(CodeBuffer buffer) {
    emitStaticFunctionsWithNamer(buffer,
                                 compiler.codegenWorld.generatedCode,
                                 namer.getName);
    emitStaticFunctionsWithNamer(buffer,
                                 compiler.codegenWorld.generatedBailoutCode,
                                 namer.getBailoutName);
  }

  void emitStaticFunctionGetters(CodeBuffer buffer) {
    Set<FunctionElement> functionsNeedingGetter =
        compiler.codegenWorld.staticFunctionsNeedingGetter;
    for (FunctionElement element in functionsNeedingGetter) {
      // The static function does not have the correct name. Since
      // [addParameterStubs] use the name to create its stubs we simply
      // create a fake element with the correct name.
      // Note: the callElement will not have any enclosingElement.
      FunctionElement callElement =
          new ClosureInvocationElement(Namer.CLOSURE_INVOCATION_NAME, element);
      String staticName = namer.getName(element);
      String invocationName = namer.instanceMethodName(callElement);
      String fieldAccess = '$isolateProperties.$staticName';
      buffer.add("$fieldAccess.$invocationName = $fieldAccess;\n");
      addParameterStubs(callElement, (String name, CodeBuffer value) {
        buffer.add('$fieldAccess.$name = $value;\n');
      });
      // If a static function is used as a closure we need to add its name
      // in case it is used in spawnFunction.
      String fieldName = namer.STATIC_CLOSURE_NAME_NAME;
      buffer.add('$fieldAccess.$fieldName = "$staticName";\n');
    }
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [member] must be a declaration element.
   */
  void emitDynamicFunctionGetter(FunctionElement member,
                                 DefineMemberFunction defineInstanceMember) {
    assert(invariant(member, member.isDeclaration));
    // For every method that has the same name as a property-get we create a
    // getter that returns a bound closure. Say we have a class 'A' with method
    // 'foo' and somewhere in the code there is a dynamic property get of
    // 'foo'. Then we generate the following code (in pseudo Dart/JavaScript):
    //
    // class A {
    //    foo(x, y, z) { ... } // Original function.
    //    get foo { return new BoundClosure499(this, "foo"); }
    // }
    // class BoundClosure499 extends Closure {
    //   var self;
    //   BoundClosure499(this.self, this.name);
    //   $call3(x, y, z) { return self[name](x, y, z); }
    // }

    // TODO(floitsch): share the closure classes with other classes
    // if they share methods with the same signature. Currently we do this only
    // if there are no optional parameters. Closures with optional parameters
    // are more difficult to canonicalize because they would need to have the
    // same default values.

    bool hasOptionalParameters = member.optionalParameterCount(compiler) != 0;
    int parameterCount = member.parameterCount(compiler);

    String closureClass =
        hasOptionalParameters ? null : boundClosureCache[parameterCount];
    if (closureClass === null) {
      // Either the class was not cached yet, or there are optional parameters.
      // Create a new closure class.
      SourceString name = const SourceString("BoundClosure");
      ClassElement closureClassElement = new ClosureClassElement(
          name, compiler, member, member.getCompilationUnit());
      String mangledName = namer.getName(closureClassElement);
      String superName = namer.getName(closureClassElement.superclass);
      needsClosureClass = true;

      // Define the constructor with a name so that Object.toString can
      // find the class name of the closure class.
      boundClosureBuffer.add("""
$classesCollector.$mangledName = {'':
 ['self', 'target'],
 'super': '$superName',
""");
      // Now add the methods on the closure class. The instance method does not
      // have the correct name. Since [addParameterStubs] use the name to create
      // its stubs we simply create a fake element with the correct name.
      // Note: the callElement will not have any enclosingElement.
      FunctionElement callElement =
          new ClosureInvocationElement(Namer.CLOSURE_INVOCATION_NAME, member);

      String invocationName = namer.instanceMethodName(callElement);
      List<String> arguments = new List<String>(parameterCount);
      for (int i = 0; i < parameterCount; i++) {
        arguments[i] = "p$i";
      }
      String joinedArgs = Strings.join(arguments, ", ");
      boundClosureBuffer.add(
          "$invocationName: function($joinedArgs) {");
      boundClosureBuffer.add(" return this.self[this.target]($joinedArgs);");
      boundClosureBuffer.add(" }");
      addParameterStubs(callElement, (String stubName, CodeBuffer memberValue) {
        boundClosureBuffer.add(',\n $stubName: $memberValue');
      });
      boundClosureBuffer.add("\n};\n");

      closureClass = namer.isolateAccess(closureClassElement);

      // Cache it.
      if (!hasOptionalParameters) {
        boundClosureCache[parameterCount] = closureClass;
      }
    }

    // And finally the getter.
    String getterName = namer.getterName(member.getLibrary(), member.name);
    String targetName = namer.instanceMethodName(member);
    CodeBuffer getterBuffer = new CodeBuffer();
    getterBuffer.add(
        "function() { return new $closureClass(this, '$targetName'); }");
    defineInstanceMember(getterName, getterBuffer);
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [member] must be a declaration element.
   */
  void emitCallStubForGetter(Element member,
                             Set<Selector> selectors,
                             DefineMemberFunction defineInstanceMember) {
    assert(invariant(member, member.isDeclaration));
    LibraryElement memberLibrary = member.getLibrary();
    String getter;
    if (member.isGetter()) {
      getter = "this.${namer.getterName(member.getLibrary(), member.name)}()";
    } else {
      String name = namer.instanceFieldName(memberLibrary, member.name);
      getter = "this.$name";
    }
    for (Selector selector in selectors) {
      if (selector.applies(member, compiler)) {
        String invocationName =
            namer.instanceMethodInvocationName(memberLibrary, member.name,
                                               selector);
        SourceString callName = Namer.CLOSURE_INVOCATION_NAME;
        String closureCallName =
            namer.instanceMethodInvocationName(memberLibrary, callName,
                                               selector);
        List<String> arguments = <String>[];
        for (int i = 0; i < selector.argumentCount; i++) {
          arguments.add("arg$i");
        }
        String joined = Strings.join(arguments, ", ");
        CodeBuffer getterBuffer = new CodeBuffer();
        getterBuffer.add(
            "function($joined) { return $getter.$closureCallName($joined); }");
        defineInstanceMember(invocationName, getterBuffer);
      }
    }
  }

  void emitStaticNonFinalFieldInitializations(CodeBuffer buffer) {
    ConstantHandler handler = compiler.constantHandler;
    List<VariableElement> staticNonFinalFields =
        handler.getStaticNonFinalFieldsForEmission();
    for (Element element in staticNonFinalFields) {
      buffer.add('$isolateProperties.${namer.getName(element)} = ');
      compiler.withCurrentElement(element, () {
          Constant initialValue = handler.getInitialValueFor(element);
          writeConstantToBuffer(initialValue, buffer);
        });
      buffer.add(';\n');
    }
  }

  void emitLazilyInitializedStaticFields(CodeBuffer buffer) {
    ConstantHandler handler = compiler.constantHandler;
    List<VariableElement> lazyFields =
        handler.getLazilyInitializedFieldsForEmission();
    if (!lazyFields.isEmpty()) {
      needsLazyInitializer = true;
      for (VariableElement element in lazyFields) {
        assert(compiler.codegenWorld.generatedBailoutCode[element] === null);
        StringBuffer code = compiler.codegenWorld.generatedCode[element];
        assert(code != null);
        // The code only computes the initial value. We build the lazy-check
        // here:
        //   lazyInitializer(prototype, 'name', fieldName, getterName, initial);
        // The name is used for error reporting. The 'initial' must be a
        // closure that constructs the initial value.
        buffer.add("$lazyInitializerName(");
        buffer.add(isolateProperties);
        buffer.add(", '");
        buffer.add(element.name.slowToString());
        buffer.add("', '");
        buffer.add(namer.getName(element));
        buffer.add("', '");
        buffer.add(namer.getLazyInitializerName(element));
        buffer.add("', ");
        buffer.add(code);
        buffer.add(");\n");
      }
    }
  }

  void emitCompileTimeConstants(CodeBuffer buffer) {
    ConstantHandler handler = compiler.constantHandler;
    List<Constant> constants = handler.getConstantsForEmission();
    bool addedMakeConstantList = false;
    for (Constant constant in constants) {
      // No need to emit functions. We already did that.
      if (constant.isFunction()) continue;

      String name = namer.constantName(constant);
      // The name is null when the constant is already a JS constant.
      // TODO(floitsch): every constant should be registered, so that we can
      // share the ones that take up too much space (like some strings).
      if (name === null) continue;
      if (!addedMakeConstantList && constant.isList()) {
        addedMakeConstantList = true;
        emitMakeConstantList(buffer);
      }
      buffer.add('$isolateProperties.$name = ');
      writeConstantToBuffer(constant, buffer, emitCanonicalVersion: false);
      buffer.add(';\n');
    }
  }

  void emitMakeConstantList(CodeBuffer buffer) {
    buffer.add(namer.ISOLATE);
    buffer.add(r'''.makeConstantList = function(list) {
  list.immutable$list = true;
  list.fixed$length = true;
  return list;
};
''');
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [member] must be a declaration element.
   */
  void emitExtraAccessors(Element member,
                          DefineMemberFunction defineInstanceMember) {
    assert(invariant(member, member.isDeclaration));
    if (member.isGetter() || member.isField()) {
      Set<Selector> selectors = compiler.codegenWorld.invokedNames[member.name];
      if (selectors !== null && !selectors.isEmpty()) {
        emitCallStubForGetter(member, selectors, defineInstanceMember);
      }
    } else if (member.isFunction()) {
      if (compiler.codegenWorld.hasInvokedGetter(member, compiler)) {
        emitDynamicFunctionGetter(member, defineInstanceMember);
      }
    }
  }

  void emitNoSuchMethodHandlers(DefineMemberFunction defineInstanceMember) {
    // Do not generate no such method handlers if there is no class.
    if (compiler.codegenWorld.instantiatedClasses.isEmpty()) return;

    String noSuchMethodName =
        namer.publicInstanceMethodNameByArity(Compiler.NO_SUCH_METHOD, 2);

    // Keep track of the JavaScript names we've already added so we
    // do not introduce duplicates (bad for code size).
    Set<String> addedJsNames = new Set<String>();

    // Keep track of the noSuchMethod holders for each possible
    // receiver type.
    Map<ClassElement, Set<ClassElement>> noSuchMethodHolders =
        new Map<ClassElement, Set<ClassElement>>();
    Set<ClassElement> noSuchMethodHoldersFor(DartType type) {
      ClassElement element = type.element;
      Set<ClassElement> result = noSuchMethodHolders[element];
      if (result === null) {
        // For now, we check the entire world to see if an object of
        // the given type may have a user-defined noSuchMethod
        // implementation. We could do better by only looking at
        // instantiated (or otherwise needed) classes.
        result = compiler.world.findNoSuchMethodHolders(type);
        noSuchMethodHolders[element] = result;
      }
      return result;
    }

    CodeBuffer generateMethod(String methodName, Selector selector) {
      CodeBuffer args = new CodeBuffer();
      for (int i = 0; i < selector.argumentCount; i++) {
        if (i != 0) args.add(', ');
        args.add('\$$i');
      }
      CodeBuffer buffer = new CodeBuffer();
      buffer.add('function($args) {\n');
      buffer.add('  return this.$noSuchMethodName("$methodName", [$args]);\n');
      buffer.add(' }');
      return buffer;
    }

    void addNoSuchMethodHandlers(SourceString ignore, Set<Selector> selectors) {
      // Cache the object class and type.
      ClassElement objectClass = compiler.objectClass;
      DartType objectType = objectClass.computeType(compiler);

      for (Selector selector in selectors) {
        // Introduce a helper function that determines if the given
        // class has a member that matches the current name and
        // selector (grabbed from the scope).
        bool hasMatchingMember(ClassElement holder) {
          Element element = holder.lookupMember(selector.name);
          if (element === null) return false;

          // TODO(kasperl): Consider folding this logic into the
          // Selector.applies() method.
          if (element is AbstractFieldElement) {
            AbstractFieldElement field = element;
            if (selector.kind === SelectorKind.GETTER) {
              return field.getter !== null;
            } else if (selector.kind === SelectorKind.SETTER) {
              return field.setter !== null;
            } else {
              return false;
            }
          }
          return selector.applies(element, compiler);
        }

        // If the selector is typed, we check to see if that type may
        // have a user-defined noSuchMethod implementation. If not, we
        // skip the selector altogether.
        DartType receiverType = objectType;
        ClassElement receiverClass = objectClass;
        if (selector is TypedSelector) {
          TypedSelector typedSelector = selector;
          receiverType = typedSelector.receiverType;
          receiverClass = receiverType.element;
        }

        // If the receiver class is guaranteed to have a member that
        // matches what we're looking for, there's no need to
        // introduce a noSuchMethod handler. It will never be called.
        //
        // As an example, consider this class hierarchy:
        //
        //                   A    <-- noSuchMethod
        //                  / \
        //                 C   B  <-- foo
        //
        // If we know we're calling foo on an object of type B we
        // don't have to worry about the noSuchMethod method in A
        // because objects of type B implement foo. On the other hand,
        // if we end up calling foo on something of type C we have to
        // add a handler for it.
        if (hasMatchingMember(receiverClass)) continue;

        // If the holders of all user-defined noSuchMethod
        // implementations that might be applicable to the receiver
        // type have a matching member for the current name and
        // selector, we avoid introducing a noSuchMethod handler.
        //
        // As an example, consider this class hierarchy:
        //
        //                       A    <-- foo
        //                      / \
        //   noSuchMethod -->  B   C  <-- bar
        //                     |   |
        //                     C   D  <-- noSuchMethod
        //
        // When calling foo on an object of type A, we know that the
        // implementations of noSuchMethod are in the classes B and D
        // that also (indirectly) implement foo, so we do not need a
        // handler for it.
        //
        // If we're calling bar on an object of type D, we don't need
        // the handler either because all objects of type D implement
        // bar through inheritance.
        //
        // If we're calling bar on an object of type A we do need the
        // handler because we may have to call B.noSuchMethod since B
        // does not implement bar.
        Set<ClassElement> holders = noSuchMethodHoldersFor(receiverType);
        if (holders.every(hasMatchingMember)) continue;

        String jsName = null;
        String methodName = null;
        String nameString = selector.name.slowToString();
        if (selector.isGetter()) {
          jsName = namer.getterName(selector.library, selector.name);
          methodName = 'get:$nameString';
        } else if (selector.isSetter()) {
          jsName = namer.setterName(selector.library, selector.name);
          methodName = 'set:$nameString';
        } else if (selector.isCall()) {
          jsName = namer.instanceMethodInvocationName(
              selector.library, selector.name, selector);
          methodName = nameString;
        } else {
          // We simply ignore selectors that do not need
          // noSuchMethod handlers.
          continue;
        }

        if (!addedJsNames.contains(jsName)) {
          CodeBuffer jsCode = generateMethod(methodName, selector);
          defineInstanceMember(jsName, jsCode);
          addedJsNames.add(jsName);
        }
      }
    }

    compiler.codegenWorld.invokedNames.forEach(addNoSuchMethodHandlers);
    compiler.codegenWorld.invokedGetters.forEach(addNoSuchMethodHandlers);
    compiler.codegenWorld.invokedSetters.forEach(addNoSuchMethodHandlers);
  }

  String buildIsolateSetup(CodeBuffer buffer,
                           Element appMain,
                           Element isolateMain) {
    String mainAccess = "${namer.isolateAccess(appMain)}";
    String currentIsolate = "${namer.CURRENT_ISOLATE}";
    String mainEnsureGetter = '';
    // Since we pass the closurized version of the main method to
    // the isolate method, we must make sure that it exists.
    if (!compiler.codegenWorld.staticFunctionsNeedingGetter.contains(appMain)) {
      Selector selector = new Selector.callClosure(0);
      String invocationName = "${namer.closureInvocationName(selector)}";
      mainEnsureGetter = "$mainAccess.$invocationName = $mainAccess";
    }

    // TODO(ngeoffray): These globals are currently required by the isolate
    // library. They should be removed.
    buffer.add("""
var \$globalThis = $currentIsolate;
var \$globalState;
var \$globals;
var \$isWorker = false;
var \$supportsWorkers = false;
var \$thisScriptUrl;
function \$static_init(){};

function \$initGlobals(context) {
  context.isolateStatics = new ${namer.ISOLATE}();
}
function \$setGlobals(context) {
  $currentIsolate = context.isolateStatics;
  \$globalThis = $currentIsolate;
}
$mainEnsureGetter
""");
  return "${namer.isolateAccess(isolateMain)}($mainAccess)";
  }

  emitMain(CodeBuffer buffer) {
    if (compiler.isMockCompilation) return;
    Element main = compiler.mainApp.find(Compiler.MAIN);
    String mainCall = null;
    if (compiler.isolateLibrary != null) {
      Element isolateMain =
        compiler.isolateLibrary.find(Compiler.START_ROOT_ISOLATE);
      mainCall = buildIsolateSetup(buffer, main, isolateMain);
    } else {
      mainCall = '${namer.isolateAccess(main)}()';
    }
    buffer.add("""

//
// BEGIN invoke [main].
//
if (typeof document != 'undefined' && document.readyState != 'complete') {
  document.addEventListener('readystatechange', function () {
    if (document.readyState == 'complete') {
      if (typeof dartMainRunner == 'function') {
        dartMainRunner(function() { ${mainCall}; });
      } else {
        ${mainCall};
      }
    }
  }, false);
} else {
  if (typeof dartMainRunner == 'function') {
    dartMainRunner(function() { ${mainCall}; });
  } else {
    ${mainCall};
  }
}
//
// END invoke [main].
//

""");
  }

  String assembleProgram() {
    measure(() {
      mainBuffer.add(HOOKS_API_USAGE);
      mainBuffer.add('function ${namer.ISOLATE}() {}\n');
      mainBuffer.add('init();\n\n');
      // Shorten the code by using "$$" as temporary.
      classesCollector = r"$$";
      mainBuffer.add('var $classesCollector = {};\n');
      // Shorten the code by using [namer.CURRENT_ISOLATE] as temporary.
      isolateProperties = namer.CURRENT_ISOLATE;
      mainBuffer.add('var $isolateProperties = $isolatePropertiesName;\n');
      emitClasses(mainBuffer);
      mainBuffer.add(boundClosureBuffer);
      // Clear the buffer, so that we can reuse it for the native classes.
      boundClosureBuffer.clear();
      emitStaticFunctions(mainBuffer);
      emitStaticFunctionGetters(mainBuffer);
      // We need to finish the classes before we construct compile time
      // constants.
      emitFinishClassesInvocationIfNecessary(mainBuffer);
      emitCompileTimeConstants(mainBuffer);
      // Static field initializations require the classes and compile-time
      // constants to be set up.
      emitStaticNonFinalFieldInitializations(mainBuffer);
      emitLazilyInitializedStaticFields(mainBuffer);
      if (compiler.enabledRuntimeType) {
        mainBuffer.add('$isolateProperties.runtimeTypeCache = {};\n');
      }

      isolateProperties = isolatePropertiesName;
      // The following code should not use the short-hand for the
      // initialStatics.
      mainBuffer.add('var ${namer.CURRENT_ISOLATE} = null;\n');
      mainBuffer.add(boundClosureBuffer);
      emitFinishClassesInvocationIfNecessary(mainBuffer);
      // After this assignment we will produce invalid JavaScript code if we use
      // the classesCollector variable.
      classesCollector = 'classesCollector should not be used from now on';

      emitFinishIsolateConstructorInvocation(mainBuffer);
      mainBuffer.add(
        'var ${namer.CURRENT_ISOLATE} = new ${namer.ISOLATE}();\n');

      nativeEmitter.assembleCode(mainBuffer);
      emitMain(mainBuffer);
      mainBuffer.add('function init() {\n');
      mainBuffer.add('$isolateProperties = {};\n');
      addDefineClassAndFinishClassFunctionsIfNecessary(mainBuffer);
      addLazyInitializerFunctionIfNecessary(mainBuffer);
      emitFinishIsolateConstructor(mainBuffer);
      mainBuffer.add('}\n');
      compiler.assembledCode = mainBuffer.toString();

      if (generateSourceMap) {
        SourceFile compiledFile = new SourceFile(null, compiler.assembledCode);
        String sourceMap = buildSourceMap(mainBuffer, compiledFile);
        // TODO(podivilov): We should find a better way to return source maps to
        // compiler. Using diagnostic handler for that purpose is a temporary
        // hack.
        compiler.reportDiagnostic(
            null, sourceMap, new api.Diagnostic(-1, 'source map'));
      }
    });
    return compiler.assembledCode;
  }

  String buildSourceMap(CodeBuffer buffer, SourceFile compiledFile) {
    SourceMapBuilder sourceMapBuilder = new SourceMapBuilder();
    buffer.forEachSourceLocation(sourceMapBuilder.addMapping);
    return sourceMapBuilder.build(compiledFile);
  }
}

typedef void DefineMemberFunction(String invocationName, CodeBuffer definition);

const String HOOKS_API_USAGE = """
// Generated by dart2js, the Dart to JavaScript compiler.
// The code supports the following hooks:
// dartPrint(message)   - if this function is defined it is called
//                        instead of the Dart [print] method.
// dartMainRunner(main) - if this function is defined, the Dart [main]
//                        method will not be invoked directly.
//                        Instead, a closure that will invoke [main] is
//                        passed to [dartMainRunner].
""";
