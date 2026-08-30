import assert from "node:assert/strict";
import test from "node:test";

import {
  StorePersistence,
  type TimerScheduler,
} from "../src/store-persistence.ts";

class FakeTimers implements TimerScheduler {
  #nextId = 1;
  #callbacks = new Map<number, () => void>();

  get pendingCount(): number {
    return this.#callbacks.size;
  }

  setTimeout(callback: () => void, _delayMs: number): number {
    const id = this.#nextId++;
    this.#callbacks.set(id, callback);
    return id;
  }

  clearTimeout(id: number): void {
    this.#callbacks.delete(id);
  }
}

test("flush cancels every debounce and saves one latest snapshot immediately", async () => {
  let state = { page: 1, zoom: 1 };
  const saved: Array<typeof state> = [];
  const timers = new FakeTimers();
  const persistence = new StorePersistence(
    () => ({ ...state }),
    async (snapshot) => {
      saved.push(snapshot);
    },
    timers,
  );

  persistence.schedule("reading-position", 800);
  state = { page: 12, zoom: 1.4 };
  persistence.schedule("zoom", 400);

  await persistence.flush();

  assert.equal(timers.pendingCount, 0);
  assert.deepEqual(saved, [{ page: 12, zoom: 1.4 }]);
});

test("flush queues the final snapshot behind an older in-flight save", async () => {
  let state = { page: 3, zoom: 1 };
  const saved: Array<typeof state> = [];
  let releaseFirstSave!: () => void;
  const firstSaveGate = new Promise<void>((resolve) => {
    releaseFirstSave = resolve;
  });
  let markFirstSaveStarted!: () => void;
  const firstSaveStarted = new Promise<void>((resolve) => {
    markFirstSaveStarted = resolve;
  });
  let saveCount = 0;
  const persistence = new StorePersistence(
    () => ({ ...state }),
    async (snapshot) => {
      saved.push(snapshot);
      saveCount += 1;
      if (saveCount === 1) {
        markFirstSaveStarted();
        await firstSaveGate;
      }
    },
    new FakeTimers(),
  );

  const firstSave = persistence.persist();
  await firstSaveStarted;
  state = { page: 18, zoom: 1.75 };
  const flush = persistence.flush();

  assert.deepEqual(saved, [{ page: 3, zoom: 1 }]);
  releaseFirstSave();
  await Promise.all([firstSave, flush]);

  assert.deepEqual(saved, [
    { page: 3, zoom: 1 },
    { page: 18, zoom: 1.75 },
  ]);
});

test("flush drains saves scheduled while its final snapshot is in flight", async () => {
  let state = { page: 5, zoom: 1 };
  const saved: Array<typeof state> = [];
  const timers = new FakeTimers();
  let releaseFirstSave!: () => void;
  const firstSaveGate = new Promise<void>((resolve) => {
    releaseFirstSave = resolve;
  });
  let markFirstSaveStarted!: () => void;
  const firstSaveStarted = new Promise<void>((resolve) => {
    markFirstSaveStarted = resolve;
  });
  let saveCount = 0;
  const events: string[] = [];
  const persistence = new StorePersistence(
    () => ({ ...state }),
    async (snapshot) => {
      events.push(`save:${snapshot.page}`);
      saved.push(snapshot);
      saveCount += 1;
      if (saveCount === 1) {
        markFirstSaveStarted();
        await firstSaveGate;
      }
    },
    timers,
  );

  const flush = persistence.flush(async () => {
    events.push("finalize");
  });
  await firstSaveStarted;
  state = { page: 21, zoom: 2 };
  persistence.schedule("late-reading-position", 800);

  assert.equal(timers.pendingCount, 0);
  releaseFirstSave();
  await flush;

  assert.deepEqual(saved, [
    { page: 5, zoom: 1 },
    { page: 21, zoom: 2 },
  ]);
  assert.deepEqual(events, ["save:5", "save:21", "finalize"]);
});
