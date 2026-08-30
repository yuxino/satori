export interface TimerScheduler {
  setTimeout(callback: () => void, delayMs: number): number;
  clearTimeout(id: number): void;
}

/**
 * Serializes complete Store snapshots and owns every debounce that can delay
 * one. `flush` cancels those delays and queues one final, latest snapshot.
 */
export class StorePersistence<T> {
  #queue: Promise<void> = Promise.resolve();
  #timers = new Map<string, number>();
  #draining = false;
  readonly #snapshot: () => T;
  readonly #save: (snapshot: T) => Promise<void>;
  readonly #timerScheduler: TimerScheduler;

  constructor(
    snapshot: () => T,
    save: (snapshot: T) => Promise<void>,
    timerScheduler: TimerScheduler,
  ) {
    this.#snapshot = snapshot;
    this.#save = save;
    this.#timerScheduler = timerScheduler;
  }

  persist(): Promise<void> {
    const snapshot = this.#snapshot();
    const next = this.#queue
      .catch(() => undefined)
      .then(() => this.#save(snapshot));
    this.#queue = next;
    return next;
  }

  schedule(key: string, delayMs: number): void {
    const previous = this.#timers.get(key);
    if (previous !== undefined) this.#timerScheduler.clearTimeout(previous);
    this.#timers.delete(key);

    if (this.#draining) {
      void this.persist().catch(() => undefined);
      return;
    }

    const timer = this.#timerScheduler.setTimeout(() => {
      this.#timers.delete(key);
      void this.persist().catch(() => undefined);
    }, delayMs);
    this.#timers.set(key, timer);
  }

  async flush(finalize: () => Promise<void> = async () => undefined): Promise<void> {
    this.#draining = true;
    for (const timer of this.#timers.values()) {
      this.#timerScheduler.clearTimeout(timer);
    }
    this.#timers.clear();
    this.persist();

    try {
      while (true) {
        const pending = this.#queue;
        await pending;
        if (pending === this.#queue) {
          // Invoke the native exit synchronously from the stable-queue
          // continuation, before another renderer microtask can schedule work.
          await finalize();
          return;
        }
      }
    } catch (error) {
      this.#draining = false;
      throw error;
    }
  }

  /** Resume normal debouncing if the native exit command itself fails. */
  resume(): void {
    this.#draining = false;
  }
}
