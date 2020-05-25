#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
const ts = require('typescript');
const prettier = require('prettier');
const argv = require('yargs')
  .usage('Usage: $0 [options] <pathish>')
  .options({
    stdout: {
      type: 'boolean',
      description: 'print transpilation to stdout'
    }
  })
  .demandCommand(1)
  .help('help').argv;

function resolveTypeNodeByName(typeChecker, name) {
  if (name === 'Array') {
    return ts.createKeywordTypeNode(ts.SyntaxKind.ArrayType);
  }

  const symbol = typeChecker.resolveName(name, undefined, ts.SymbolFlags.Type, false);
  if (symbol == null) {
    return ts.createKeywordTypeNode(ts.SyntaxKind.AnyKeyword);
  }

  const type = typeChecker.getDeclaredTypeOfSymbol(symbol);
  return typeChecker.typeToTypeNode(type);
}

function nodeName(node) {
  if (ts.isIdentifier(node)) {
    return node;
  }

  if (node.name == null) {
    return '<INVALID>';
  }

  return node.name.expression ? node.name.expression.escapedText : node.name.escapedText;
}

function parameterIsOptional(node) {
  const jsDocTags = ts.getJSDocParameterTags(node);
  if (jsDocTags.length) {
    return jsDocTags[0].isBracketed;
  }

  // detect if we have a conventional callback: (err, res) => {}, and
  // make the parameters optional if so.
  const parent = node.parent;
  if (isFunctionLike(parent)) {
    if (parent.parameters.length === 2) {
      if (nodeName(node).match(/err/) || nodeName(parent.parameters[0]).match(/err/)) {
        return true;
      }
    }

    // fallthrough, is the previous prarameter optional?
    if (parent.parameters.length > 1) {
      const idx = parent.parameters.indexOf(node);

      if (idx > 0) {
        const previousNode = parent.parameters[idx - 1];
        return parameterIsOptional(previousNode);
      }
    }
  }

  return false;
}

function resolveNodeTypeNode(typeChecker, node) {
  const typeNode = ts.getJSDocType(node);
  if (typeNode) {
    if (ts.isToken(typeNode)) {
      return ts.createKeywordTypeNode(typeNode.kind);
    } else if (ts.isTypeReferenceNode(typeNode)) {
      return resolveTypeNodeByName(typeChecker, typeNode.typeName.escapedText);
    }
  }

  if (nodeName(node) === 'callback') {
    return resolveTypeNodeByName(typeChecker, 'Function');
  }

  return ts.createKeywordTypeNode(ts.SyntaxKind.AnyKeyword);
}

function isFunctionLike(node) {
  return (
    ts.isFunctionDeclaration(node) || ts.isFunctionExpression(node) || ts.isArrowFunction(node)
  );
}

function isRequireAssignment(node) {
  return (
    ts.isVariableStatement(node) &&
    node.declarationList.declarations.length === 1 &&
    node.declarationList.declarations[0].initializer &&
    ts.isCallExpression(node.declarationList.declarations[0].initializer) &&
    node.declarationList.declarations[0].initializer.expression.escapedText === 'require'
  );
}

function makeVisitor(transformCtx, sourceFile, typeChecker, transforms) {
  const visitor = originalNode => {
    const node = ts.visitEachChild(originalNode, visitor, transformCtx);

    // translate require statements to imports
    if (isRequireAssignment(node)) {
      const declaration = node.declarationList.declarations[0];
      const moduleName = declaration.initializer.arguments[0];

      if (ts.isObjectBindingPattern(declaration.name)) {
        const binding = declaration.name;

        if (binding.elements.every(elt => ts.isIdentifier(elt.name))) {
          const importSpecifiers = binding.elements.map(elt =>
            ts.createImportSpecifier(undefined, elt.name)
          );

          return ts.createImportDeclaration(
            undefined,
            undefined,
            ts.createImportClause(undefined, ts.createNamedImports(importSpecifiers), false),
            moduleName
          );
        }
      } else {
        return ts.createImportDeclaration(
          undefined,
          undefined,
          ts.createImportClause(declaration.name, undefined, false),
          moduleName
        );
      }
    }

    // translate module.exports to ts expor syntax
    if (isModuleExportsExpression(node)) {
      const exported = node.expression.right;

      if (ts.isObjectLiteralExpression(exported)) {
        if (
          !exported.properties.every(
            prop => ts.isShorthandPropertyAssignment(prop) || ts.isIdentifier(prop.initializer)
          )
        ) {
          return node;
        }

        const exports = exported.properties.map(prop => {
          if (ts.isShorthandPropertyAssignment(prop)) {
            return ts.createExportSpecifier(undefined, prop.name);
          }

          return ts.createExportSpecifier(prop.initializer, prop.name);
        });

        return ts.createExportDeclaration(
          undefined,
          undefined,
          ts.createNamedExports(exports),
          undefined,
          false
        );
      } else {
        return ts.createExportAssignment(undefined, undefined, undefined, exported);
      }
    }

    // we can immediately correct missing types on the first phase
    if (ts.isParameter(node) && node.type == null) {
      return ts.updateParameter(
        node,
        node.decorators,
        node.modifiers,
        node.dotDotDotToken,
        node.name,
        parameterIsOptional(node)
          ? ts.createToken(ts.SyntaxKind.QuestionToken)
          : node.questionToken,
        resolveNodeTypeNode(typeChecker, node),
        node.initializer
      );
    }

    if (isFunctionLike(node) && transforms.has(node.pos)) {
      const parameters = node.parameters;
      parameters.unshift(transforms.get(node.pos)[0]);

      if (ts.isFunctionDeclaration(node)) {
        return ts.updateFunctionDeclaration(
          node,
          node.decorators,
          node.modifiers,
          node.asteriskToken,
          node.name,
          node.typeParameters,
          parameters,
          node.type,
          node.body
        );
      }

      if (ts.isFunctionExpression(node)) {
        return ts.updateFunctionExpression(
          node,
          node.modifiers,
          node.asteriskToken,
          node.name,
          node.typeParameters,
          parameters,
          node.type,
          node.body
        );
      }

      if (ts.isArrowFunction(node)) {
        return ts.updateArrowFunction(
          node,
          node.modifiers,
          node.typeParameters,
          parameters,
          node.type,
          node.equalsGreaterThanToken,
          node.body
        );
      }
    }

    if (ts.isClassDeclaration(node) && transforms.hasClassProperties(node.pos)) {
      const classDeclaration = node;
      const memberElements = transforms
        .classProperties(classDeclaration.pos)
        .concat(classDeclaration.members);

      return ts.updateClassDeclaration(
        classDeclaration,
        classDeclaration.decorators,
        classDeclaration.modifiers,
        classDeclaration.name,
        classDeclaration.typeParameters,
        classDeclaration.heritageClauses,
        memberElements
      );
    }

    if (ts.isObjectLiteralExpression(node) && transforms.has(node.pos)) {
      return ts.updateNode(transforms.get(node.pos), node);
    }

    return node;
  };

  return visitor;
}

function makeTransformer(program, transforms) {
  const typeChecker = program.getTypeChecker();

  return transformCtx => {
    return sourceFile => {
      return ts.visitNode(
        sourceFile,
        makeVisitor(transformCtx, sourceFile, typeChecker, transforms)
      );
    };
  };
}

function findParent(node, predicate) {
  if (node.parent == null) return;
  if (predicate(node)) return node;
  return findParent(node.parent, predicate);
}

function isModuleExportsExpression(node) {
  return (
    ts.isExpressionStatement(node) &&
    ts.isBinaryExpression(node.expression) &&
    ts.isPropertyAccessExpression(node.expression.left) &&
    node.expression.left.expression.escapedText === 'module' &&
    node.expression.left.name.escapedText === 'exports'
  );
}

function isJsSymbolType(symbol) {
  return (
    symbol.valueDeclaration &&
    symbol.valueDeclaration.initializer &&
    symbol.valueDeclaration.initializer.expression &&
    symbol.valueDeclaration.initializer.expression.escapedText === 'Symbol'
  );
}

class TransformContext {
  constructor() {
    this._transforms = new Map();
    this._properties = new Map();
  }

  has(key) {
    return this._transforms.has(key);
  }

  get(key) {
    return this._transforms.get(key);
  }

  set(key, value) {
    return this._transforms.set(key, value);
  }

  addPropertyToClass(classDeclaration, propertyNode) {
    const key = classDeclaration.pos;
    if (!this._properties.has(key)) {
      this._properties.set(key, [propertyNode]);
      return;
    }

    const propertyName = nodeName(propertyNode);
    const toAdd = this._properties.get(key);
    if (!toAdd.find(p => nodeName(p) === propertyName)) {
      this._properties.get(classDeclaration.pos).push(propertyNode);
    }
  }

  hasClassProperties(pos) {
    return this._properties.has(pos);
  }

  classProperties(pos) {
    return this._properties.has(pos) ? this._properties.get(pos) : [];
  }
}

function scanForTransforms(program, sourceFile) {
  const transforms = new TransformContext();
  const checker = program.getTypeChecker();
  const semanticErrors = program.getSemanticDiagnostics(sourceFile);

  function visit(node) {
    ts.forEachChild(node, visit);

    const nodeError = semanticErrors.find(err => err.start === node.getStart());
    if (nodeError == null) {
      return;
    }

    // fix implicit `this` access in strict mode
    if (node.kind === ts.SyntaxKind.ThisKeyword && nodeError.code === 2683) {
      const parent = findParent(node, isFunctionLike);
      if (parent) {
        const propertyName = 'this';
        const property = ts.createParameter(
          /*decorators*/ undefined,
          /*modifiers*/ undefined,
          /*dotDotDotToken*/ undefined,
          propertyName,
          /*questionToken*/ undefined,
          ts.createKeywordTypeNode(ts.SyntaxKind.AnyKeyword),
          /*initializer*/ undefined
        );

        transforms.set(parent.pos, [property]);
      }
    }

    if (nodeError.code === 2339 && ts.isPropertyAccessExpression(node.parent)) {
      const accessExpression = node.parent;
      const symbol = checker.getSymbolAtLocation(accessExpression.expression);

      if (symbol) {
        // for situations where a property is being added to an object literal, need to make it: const x = { a: 'hello' } as any;
        if (ts.isVariableDeclaration(symbol.valueDeclaration)) {
          if (
            symbol.valueDeclaration.initializer &&
            ts.isObjectLiteralExpression(symbol.valueDeclaration.initializer)
          ) {
            const objectLiteral = symbol.valueDeclaration.initializer;
            const asExpression = ts.createAsExpression(
              objectLiteral,
              ts.createKeywordTypeNode(ts.SyntaxKind.AnyKeyword)
            );

            transforms.set(objectLiteral.pos, asExpression);
          }
        } else if (ts.isClassDeclaration(symbol.valueDeclaration)) {
          const classDeclaration = symbol.valueDeclaration;
          const propertyName = nodeName(node);
          const property = ts.createProperty(
            /*decorators*/ undefined,
            /*modifiers*/ undefined,
            propertyName,
            /*questionToken*/ undefined,
            ts.createKeywordTypeNode(ts.SyntaxKind.AnyKeyword),
            /*initializer*/ undefined
          );

          transforms.addPropertyToClass(classDeclaration, property);
        }
      }
    }

    if (
      (nodeError.code === 7053 || nodeError.code === 2538) &&
      ts.isElementAccessExpression(node.parent)
    ) {
      const accessExpression = node.parent;
      if (accessExpression.expression.kind === ts.SyntaxKind.ThisKeyword) {
        const symbol = checker.getSymbolAtLocation(accessExpression.expression);
        if (symbol && ts.isClassDeclaration(symbol.valueDeclaration)) {
          const classDeclaration = symbol.valueDeclaration;
          const propertyName = nodeName(accessExpression.argumentExpression);
          const propertySymbol = checker.getSymbolAtLocation(propertyName);
          const property = ts.createProperty(
            /*decorators*/ undefined,
            /*modifiers*/ undefined,
            isJsSymbolType(propertySymbol)
              ? ts.createComputedPropertyName(propertyName)
              : propertyName,
            /*questionToken*/ undefined,
            ts.createKeywordTypeNode(ts.SyntaxKind.AnyKeyword),
            /*initializer*/ undefined
          );

          transforms.addPropertyToClass(classDeclaration, property);
        }
      }
    }
  }

  ts.forEachChild(sourceFile, visit);
  return transforms;
}

function preserveNewlines(buffer) {
  return buffer.toString().replace(/\n\n/g, '/** THIS_IS_A_NEWLINE **/\n');
}

function restoreNewlines(data) {
  return data.replace(/\/\*\* THIS_IS_A_NEWLINE \*\*\//g, '\n');
}

function applyTypeInformation(fileNames, options) {
  const compilerHost = ts.createCompilerHost(options);

  const $readFile = compilerHost.readFile;
  compilerHost.readFile = fileName => {
    const baseName = `${path.basename(fileName)}`;
    if (fileNames.some(name => name.match(new RegExp(baseName)))) {
      return preserveNewlines(fs.readFileSync(path.join(__dirname, fileName)));
    }

    return $readFile.apply(null, [fileName]);
  };

  const program = ts.createProgram(fileNames, options, compilerHost);
  const printer = ts.createPrinter({
    newLine: ts.NewLineKind.LineFeed,
    removeComments: false,
    omitTrailingSemicolon: false
  });

  for (const sourceFile of program.getSourceFiles()) {
    if (sourceFile.isDeclarationFile) {
      continue;
    }

    const transforms = scanForTransforms(program, sourceFile);
    const result = ts.transform(sourceFile, [makeTransformer(program, transforms)]);

    // console.log('\n\n##### OUTPUT #####');
    const output = restoreNewlines(printer.printFile(result.transformed[0]));
    const formatted = prettier.format(output, {
      singleQuote: true,
      tabWidth: 2,
      printWidth: 100,
      arrowParens: 'avoid',
      parser: 'typescript'
    });

    if (argv.stdout) {
      console.log(formatted);
    } else {
      fs.writeFileSync(sourceFile.resolvedPath, formatted);
    }
  }
}

applyTypeInformation(argv._, {
  target: ts.ScriptTarget.ES2018,
  module: ts.ModuleKind.CommonJS,
  allowJs: false,
  checkJs: false,
  strict: true,
  declaration: false,
  importHelpers: false,
  alwaysStrict: true,
  noEmitHelpers: true,
  noEmitOnError: true
});
