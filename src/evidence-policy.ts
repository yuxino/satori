/** Select image evidence without expanding beyond the visible page implicitly. */
export function requestedEvidencePages(page: number, pageCount: number, question: string): number[] {
  const pages = new Set<number>([page]);
  const wantsPrevious = hasAffirmativeMention(
    question,
    /上一页|前一页|前文|上文|接上页|接上文/g,
  );
  const wantsNext = hasAffirmativeMention(
    question,
    /下一页|后一页|后文|接下页|往下一页/g,
  );

  if (wantsPrevious && page > 1) pages.add(page - 1);
  if (wantsNext && page < pageCount) pages.add(page + 1);
  return [...pages].sort((left, right) => left - right);
}

function hasAffirmativeMention(question: string, pattern: RegExp): boolean {
  const segments = question.split(/[，,。；;！!？?]|但(?:是)?|不过|而是|而/g);
  for (const segment of segments) {
    for (const match of segment.matchAll(pattern)) {
      const before = segment.slice(0, match.index).trimEnd();
      const after = segment.slice(match.index + match[0].length).trimStart();
      const inclusionBefore = /(?:不要|不能|别|勿)(?:再)?(?:漏掉|遗漏|省略|忽略)\s*$/.test(before);
      const inclusionAfter = /^(?:也)?(?:不要|不能|别|勿)(?:再)?(?:漏掉|遗漏|省略|忽略)/.test(after);
      const negatedBefore = !inclusionBefore
        && /(?:不要|不用|不必|无需|不需要|别|勿|不是|并非|不想|不希望|没有要求|没要求|未要求)[^，,。；;！!？?]*$/.test(before);
      const negatedAfter = !inclusionAfter && (
        /^(?:也)?(?:不用|不必|无需|不需要|不要|别|勿)(?:再|去)?(?:(?:作为|当作|用作)(?:参考|依据|证据)|看|结合|参考|发送|发|读取|用|管|考虑|解释|讲)/.test(after)
        || /^(?:也)?(?:不看|不发|不读取|不参考|不结合|不解释|不讲)/.test(after)
        || /(?:无关|不相关)/.test(after)
        || /(?:没有要求|没要求|未要求)[^，,。；;！!？?]*(?:看|结合|参考|发送|发|读取|用|考虑|解释|讲)/.test(after)
      );
      if (!negatedBefore && !negatedAfter) return true;
    }
  }
  return false;
}
