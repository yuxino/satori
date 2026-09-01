interface OutlineEvidencePlan {
  outlinePages: number[];
  chapterProbePages: number[];
}

function pageSequence(first: number, last: number, step: number): number[] {
  const pages: number[] = [];
  for (let page = first; page <= last; page += step) pages.push(page);
  return pages;
}

/**
 * The complete set of PDF pages used by the two-stage scanned-outline flow.
 * Keep the UI disclosure and the request implementation on this shared plan.
 */
export function outlineEvidencePlan(pageCount: number): OutlineEvidencePlan {
  const lastPage = Number.isFinite(pageCount) ? Math.max(0, Math.floor(pageCount)) : 0;
  const outlinePages = pageSequence(3, Math.min(lastPage, 6), 1);
  if (lastPage === 0) return { outlinePages, chapterProbePages: [] };

  const probeFirst = Math.min(20, lastPage);
  const chapterProbePages = pageSequence(probeFirst, Math.min(lastPage, 45), 2);
  return { outlinePages, chapterProbePages };
}
