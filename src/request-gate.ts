/**
 * Tracks one active async request without letting an older completion clear a
 * newer request. Invalidating the gate makes every existing token stale.
 */
export class RequestGate {
  private generation = 0;
  private activeToken: number | null = null;

  get busy(): boolean {
    return this.activeToken !== null;
  }

  begin(): number | null {
    if (this.activeToken !== null) return null;
    this.activeToken = ++this.generation;
    return this.activeToken;
  }

  isCurrent(token: number): boolean {
    return this.activeToken === token;
  }

  finish(token: number): void {
    if (this.activeToken === token) this.activeToken = null;
  }

  invalidate(): void {
    this.generation += 1;
    this.activeToken = null;
  }
}
