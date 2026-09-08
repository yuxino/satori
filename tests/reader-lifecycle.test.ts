import assert from "node:assert/strict";
import test from "node:test";

import * as budget from "../src/reader-budget.ts";
import { deferred, sourceFixture } from "./helpers/source-fixture.ts";

// Minimal geometry/DOM adapter. Layout, navigation and asynchronous work all
// run through the real ScrollReader implementation.
class Element {
  children: Element[] = [];
  parent: Element | null = null;
  className = "";
  dataset: Record<string, string> = {};
  style: Record<string, string> = { transform: "" };
  width = 0;
  height = 0;
  clientWidth = 1000;
  clientHeight = 800;
  scrollTop = 0;
  scrollLeft = 0;
  root = false;

  get isConnected(): boolean { return this.root || Boolean(this.parent?.isConnected); }
  get scrollHeight(): number {
    const spacer = this.querySelector(".scroll-spacer");
    return Math.max(this.clientHeight, Number.parseFloat(spacer?.style.height ?? "0"));
  }
  set innerHTML(_value: string) {
    for (const child of this.children) child.parent = null;
    this.children = [];
  }
  appendChild(child: Element) { child.parent = this; this.children.push(child); return child; }
  remove() {
    if (this.parent) this.parent.children = this.parent.children.filter((child) => child !== this);
    this.parent = null;
  }
  querySelector(selector: string): Element | null {
    for (const child of this.children) {
      if (child.className === selector.slice(1)) return child;
      const nested = child.querySelector(selector);
      if (nested) return nested;
    }
    return null;
  }
  scrollTo({ top }: { top: number }) { this.scrollTop = top; }
  getBoundingClientRect() {
    let surface: Element = this;
    while (surface.parent) surface = surface.parent;
    const width = Number.parseFloat(this.style.width ?? "0");
    const height = Number.parseFloat(this.style.height ?? "0");
    const left = Number.parseFloat(this.style.left ?? "0") - surface.scrollLeft;
    const top = Number.parseFloat(this.style.top ?? "0") - surface.scrollTop;
    return { left, top, width, height, right: left + width, bottom: top + height };
  }
}

function fixture() {
  const context = sourceFixture(new URL("../src/reader.ts", import.meta.url), {
    require: (name: string) => {
      assert.equal(name, "./reader-budget");
      return budget;
    },
    document: { createElement: () => new Element() },
    performance,
    requestAnimationFrame: (callback: () => void) => setTimeout(callback, 0),
  });
  const Reader = context.exports.ScrollReader as typeof import("../src/reader.ts").ScrollReader;
  const surface = new Element();
  surface.root = true;
  const pages: number[] = [];
  const rendered: number[] = [];
  const doc = {
    pageCount: 50,
    pageSizes: async () => Array.from({ length: 50 }, () => ({ width: 600, height: 800 })),
    renderPageToCanvas: async (page: number) => {
      rendered.push(page);
      const canvas = new Element();
      canvas.width = 600;
      canvas.height = 800;
      return canvas;
    },
  };
  const makeReader = (onPageChange = (page: number) => pages.push(page)) =>
    new Reader(surface as unknown as HTMLDivElement, doc as any, { onPageChange });
  return { surface, doc, pages, rendered, makeReader, reader: makeReader() };
}

test("opening at a saved later page renders that page before reporting ready", async () => {
  const f = fixture();
  await f.reader.open(40);
  assert.ok(f.rendered.includes(40), "saved page must have a canvas without relying on a later scroll event");
  assert.equal(f.pages.at(-1), 40);
});

test("pending relayout keeps the last valid page mapping", async () => {
  const f = fixture();
  await f.reader.open(12);
  const gate = deferred<Awaited<ReturnType<typeof f.doc.pageSizes>>>();
  const entered = deferred();
  const sizes = await f.doc.pageSizes();
  f.doc.pageSizes = () => { entered.resolve(); return gate.promise; };
  const zoom = f.reader.setZoom(1.5);
  await entered.promise;
  const duringLayout = f.reader.currentPage();
  gate.resolve(sizes);
  await zoom;
  assert.equal(duringLayout, 12);
  assert.equal(f.pages.at(-1), 12);
});

test("cleared reader cannot move a replacement or emit late page state", async () => {
  const f = fixture();
  await f.reader.open(12);
  const getSizes = f.doc.pageSizes;
  const sizes = await getSizes();
  const gate = deferred<typeof sizes>();
  const entered = deferred();
  f.doc.pageSizes = () => { entered.resolve(); return gate.promise; };
  const zoom = f.reader.setZoom(1.5);
  await entered.promise;
  f.reader.clear();
  f.surface.innerHTML = "";
  f.doc.pageSizes = getSizes;
  const replacement = f.makeReader(() => undefined);
  await replacement.open(3);
  const scrollTop = f.surface.scrollTop;
  const callbackCount = f.pages.length;
  const renderCount = f.rendered.length;
  gate.resolve(sizes);
  await zoom;
  await f.reader.onScroll();
  assert.equal(f.surface.scrollTop, scrollTop, "old layout must not scroll the shared surface");
  assert.equal(f.pages.length, callbackCount, "old callbacks must not overwrite the new book's last_page");
  assert.equal(f.rendered.length, renderCount, "old reader must not restart PDF work");
});

test("a render completing after clear is released without reporting a page", async () => {
  const f = fixture();
  const gate = deferred<Element>();
  const entered = deferred();
  f.doc.renderPageToCanvas = () => { entered.resolve(); return gate.promise; };
  const opening = f.reader.open(1);
  await entered.promise;
  f.reader.clear();
  const canvas = new Element();
  canvas.width = 600;
  canvas.height = 800;
  gate.resolve(canvas);
  await opening;
  assert.equal(canvas.width, 0);
  assert.equal(canvas.height, 0);
  assert.deepEqual(f.pages, []);
});
