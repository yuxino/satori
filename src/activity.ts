/** Count only an actual page transition, never same-page layout/render callbacks. */
export function pageTransitionDelta(previousPage: number, nextPage: number): 0 | 1 {
  return previousPage === nextPage ? 0 : 1;
}
