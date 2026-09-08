import assert from "node:assert/strict";
import test from "node:test";
import { sourceFixture } from "./helpers/source-fixture.ts";

class Controls {
  title = "";
  style: Record<string, string> = {};
  listeners = new Map<string, Array<(event: any) => void>>();
  children: Controls[] = [];
  append(...children: Controls[]) { this.children.push(...children); }
  appendChild(child: Controls) { this.append(child); }
  addEventListener(event: string, listener: (event: any) => void) {
    this.listeners.set(event, [...this.listeners.get(event) ?? [], listener]);
  }
  fire(event: string, properties = {}) {
    for (const listener of this.listeners.get(event) ?? []) {
      listener({ preventDefault() {}, ...properties });
    }
  }
}

function fixture(opening = true) {
  const document = new Controls();
  const surface = new Controls();
  const bottomBar = new Controls();
  const controls: Controls[] = [];
  const timers = new Map<number, () => void>();
  let nextTimer = 0;
  const calls: Array<[string, number]> = [];
  let previewing = false;
  const book = { id: "B", name: "Synthetic", last_page: 3, zoom: 1.5 };
  const context = sourceFixture(new URL("../src/main.ts", import.meta.url), {
    document: Object.assign(document, {
      createElement: () => { const control = new Controls(); controls.push(control); return control; },
      getElementById: (id: string) => id === "app" ? surface : null,
      activeElement: { tagName: "BODY" },
    }),
    window: Object.assign(new Controls(), {
      setTimeout: (callback: () => void) => { const id = ++nextTimer; timers.set(id, callback); return id; },
      clearTimeout: (id: number) => timers.delete(id),
    }),
    readerSurface: surface, bottomBar, currentBook: book, currentDoc: { pageCount: 8 },
    currentPage: 3, zoomFactor: 1.5, openingBook: opening, wheelCommitTimer: undefined,
    reader: {
      setZoom: async (value: number) => { calls.push(["set", value]); },
      previewZoom: (value: number) => { previewing = true; calls.push(["preview", value]); },
      commitZoom: async (value: number) => { previewing = false; calls.push(["commit", value]); },
    },
    store: { books: [book] }, todayPagesPending: 0,
    storePersistence: { schedule: () => undefined },
    hasPrimaryModifier: (event: { metaKey?: boolean; ctrlKey?: boolean }) => event.metaKey || event.ctrlKey,
    shouldHandlePageFlipWheel: (event: { ctrlKey?: boolean }) => !event.ctrlKey,
    bookName: (name: string) => name,
    THUMB_STEP: 40,
    updateBottomBarZoom: () => undefined,
    updateLayoutButton: () => undefined,
    renderAllThumbnails: async () => undefined,
  }, ["setupReaderSurface", "renderBottomBar", "clampZoom", "applyZoom", "persistZoom", "checkpointCurrentReadingState"], ["keydown"]);
  context.setupReaderSurface();
  context.renderBottomBar();
  const click = (title: string) => {
    const control = controls.find((control) => control.title === title);
    assert.ok(control, `production toolbar control: ${title}`);
    control.fire("click");
  };
  const drain = () => {
    for (const callback of timers.values()) callback();
    timers.clear();
  };
  const checkpoint = () => {
    context.checkpointCurrentReadingState();
    assert.equal(context.zoomFactor, 1.5);
    assert.equal(book.zoom, 1.5);
    assert.deepEqual(calls, []);
  };
  return { context, document, surface, calls, book, click, drain, checkpoint, timers, get previewing() { return previewing; } };
}

test("loading ignores actual keyboard zoom inputs without changing the next Store checkpoint", () => {
  const f = fixture();
  for (const modifier of ["metaKey", "ctrlKey"]) {
    for (const key of ["+", "-", "0"]) {
      f.document.fire("keydown", { key, [modifier]: true });
      f.checkpoint();
    }
  }
});

test("loading ignores all three actual toolbar zoom controls", () => {
  const f = fixture();
  for (const title of ["放大", "缩小", "回到适合窗口"]) {
    f.click(title);
    f.checkpoint();
  }
});

test("loading wheel and pinch events neither preview nor queue a zoom commit", () => {
  const f = fixture();
  f.surface.fire("wheel", { ctrlKey: true, deltaY: -100 });
  f.surface.fire("gesturestart");
  f.surface.fire("gesturechange", { scale: 1.5 });
  f.surface.fire("gestureend");
  assert.equal(f.timers.size, 0);
  f.checkpoint();
});

test("an accepted pinch finishes on the retained book when the next open is cancelled", () => {
  const f = fixture(false);
  f.surface.fire("gesturestart");
  f.surface.fire("gesturechange", { scale: 1.2 });
  const accepted = f.context.zoomFactor;
  f.context.openingBook = true;
  f.surface.fire("gesturechange", { scale: 2 });
  f.surface.fire("gestureend");
  // Failed preflight/cancellation leaves the same reader available in openBook.
  f.context.openingBook = false;
  assert.equal(f.context.zoomFactor, accepted);
  assert.equal(f.book.zoom, accepted);
  assert.equal(f.previewing, false, "old book must not remain stuck in selection-disabled CSS preview");
  assert.deepEqual(f.calls, [["preview", accepted], ["commit", accepted]]);
});

test("an accepted wheel preview finishes on the retained book after a failed open", () => {
  const f = fixture(false);
  f.surface.fire("wheel", { ctrlKey: true, deltaY: -100 });
  const accepted = f.context.zoomFactor;
  f.context.openingBook = true;
  f.drain();
  f.context.openingBook = false;
  assert.equal(f.timers.size, 0);
  assert.equal(f.previewing, false);
  assert.equal(f.book.zoom, accepted);
  assert.deepEqual(f.calls, [["preview", accepted], ["commit", accepted]]);
});

test("accepted gestures cannot commit into a replacement reader after a successful open", () => {
  for (const kind of ["pinch", "wheel"]) {
    const f = fixture(false);
    if (kind === "pinch") {
      f.surface.fire("gesturestart");
      f.surface.fire("gesturechange", { scale: 1.2 });
    } else {
      f.surface.fire("wheel", { ctrlKey: true, deltaY: -100 });
    }
    const calls = f.calls.length;
    f.context.reader = { commitZoom: () => assert.fail("must not commit old work into the replacement") };
    f.context.currentBook = { id: "C", zoom: 0.75 };
    f.context.zoomFactor = 0.75;
    f.surface.fire("gestureend");
    f.drain();
    assert.equal(f.calls.length, calls);
    assert.equal(f.context.zoomFactor, 0.75);
    assert.equal(f.context.currentBook.zoom, 0.75);
  }
});

test("keyboard and toolbar zoom still render and persist once loading has finished", async () => {
  const f = fixture();
  f.context.openingBook = false;
  f.document.fire("keydown", { key: "+", metaKey: true });
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(f.book.zoom, 1.65);
  f.click("放大");
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(f.book.zoom, 1.9);
  f.click("回到适合窗口");
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(f.book.zoom, 1);
  assert.deepEqual(f.calls, [["set", 1.65], ["set", 1.9], ["set", 1]]);
});

test("normal pinch and wheel gestures retain preview and persistence behavior", async () => {
  const f = fixture(false);
  f.surface.fire("gesturestart");
  f.surface.fire("gesturechange", { scale: 1.2 });
  f.surface.fire("gestureend");
  await Promise.resolve();
  assert.ok(Math.abs(f.book.zoom - 1.8) < 1e-10);
  assert.equal(f.calls[0][0], "preview");
  assert.equal(f.calls[1][0], "commit");
  f.surface.fire("wheel", { ctrlKey: true, deltaY: 100 });
  f.drain();
  await Promise.resolve();
  assert.equal(f.calls[2][0], "preview");
  assert.equal(f.calls[3][0], "commit");
  assert.equal(f.book.zoom, f.calls[3][1]);
});
