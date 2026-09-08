import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "typescript";

// Exercise production code without booting Tauri or reading an actual Store.
// TypeScript is already a build dependency; no DOM/test runtime is installed.
export function sourceFixture(
  path: URL,
  globals: Record<string, unknown>,
  functions?: string[],
): Record<string, any> {
  let source = readFileSync(path, "utf8");
  if (functions) {
    const parsed = ts.createSourceFile(path.pathname, source, ts.ScriptTarget.Latest, true);
    source = functions.map((name) => {
      const declaration = parsed.statements.find((statement) =>
        ts.isFunctionDeclaration(statement) && statement.name?.text === name);
      if (!declaration) throw new Error(`Missing production function: ${name}`);
      return declaration.getText(parsed);
    }).join("\n");
  }
  const { outputText } = ts.transpileModule(source, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS },
  });
  const context = { exports: {}, setTimeout, clearTimeout, ...globals };
  runInNewContext(outputText, context, { filename: path.pathname });
  return context;
}

export function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
