import assert from "node:assert/strict";
import test from "node:test";
import { deferred, sourceFixture } from "./helpers/source-fixture.ts";

function fixture() {
  const calls: string[] = [];
  const book = { id: "A", last_page: 12, zoom: 1.5, spread: false };
  const makeReader = (name: string) => ({
    currentPage: () => 12,
    setZoom: async (_zoom: number) => { calls.push(`${name}:zoom`); },
    setSpread: async (_spread: boolean) => { calls.push(`${name}:spread`); },
    scrollToPage: (_page: number) => { calls.push(`${name}:scroll`); },
    onScroll: async () => { calls.push(`${name}:onScroll`); },
  });
  const a = makeReader("A");
  const context = sourceFixture(new URL("../src/main.ts", import.meta.url), {
    reader: a, currentBook: book, currentDoc: {}, openingBook: false, zoomFactor: 1.5,
    store: { books: [book] },
    persist: async () => { calls.push("persist"); },
    persistZoom: () => { calls.push("persistZoom"); },
    updateLayoutButton: () => undefined,
    updateBottomBarZoom: () => undefined,
  }, ["relayoutOnResize", "clampZoom", "applyZoom", "applyLayout"]);
  const replace = () => {
    const b = { id: "B", last_page: 3, zoom: 0.75, spread: false };
    context.reader = makeReader("B");
    context.currentBook = b;
    context.currentDoc = {};
    context.zoomFactor = b.zoom;
    context.store.books.push(b);
    return b;
  };
  return { calls, context, a, book, replace };
}

test("resize finishing after a book switch cannot jump the replacement to the old page", async () => {
  const f = fixture();
  const gate = deferred();
  f.a.setZoom = () => gate.promise;
  const pending = f.context.relayoutOnResize();
  f.replace();
  gate.resolve();
  await pending;
  assert.deepEqual(f.calls, []);
});

for (const phase of ["zoom", "spread"] as const) {
  test(`layout switch finishing after a book switch during ${phase} preserves the new book's preferences`, async () => {
    const f = fixture();
    const gate = deferred();
    const entered = deferred();
    f.a[phase === "zoom" ? "setZoom" : "setSpread"] = () => {
      entered.resolve();
      return gate.promise;
    };
    const pending = f.context.applyLayout(true);
    await entered.promise;
    const b = f.replace();
    gate.resolve();
    await pending;
    assert.deepEqual(b, { id: "B", last_page: 3, zoom: 0.75, spread: false });
    assert.ok(!f.calls.some((call) => call.startsWith("B:") || call === "persist"));
  });
}

test("zoom completion after removing the current book cannot checkpoint another session", async () => {
  const f = fixture();
  const gate = deferred();
  f.a.setZoom = () => gate.promise;
  const pending = f.context.applyZoom(1.5);
  f.context.reader = null;
  f.context.currentDoc = null;
  f.context.currentBook = null;
  gate.resolve();
  await pending;
  assert.deepEqual(f.calls, []);
});

test("current reader actions still restore the anchor and save its layout preference", async () => {
  const f = fixture();
  await f.context.relayoutOnResize();
  assert.deepEqual(f.calls, ["A:zoom", "A:scroll", "A:onScroll"]);
  f.calls.length = 0;
  await f.context.applyLayout(true);
  assert.equal(f.book.spread, true);
  assert.equal(f.book.zoom, 1);
  assert.deepEqual(f.calls, ["A:zoom", "A:spread", "persist"]);
});
