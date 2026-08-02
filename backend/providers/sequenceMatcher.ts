/**
 * A port of Python's `difflib.SequenceMatcher.get_opcodes()`, restricted to
 * what the gate needs (no junk heuristics, no autojunk).
 *
 * Why not a plain Levenshtein alignment: it produces a *different* alignment.
 * For gold `[A, B]` against reading `[C]`, Levenshtein says "replace A with C,
 * delete B" while difflib says "replace [A, B] with [C]" — two different
 * stories about what happened to the text. The Python gate is the reference
 * and reports the second, and these verdict strings are what a user sees in
 * quick_confirm and what gets logged, so the two implementations telling
 * different stories about the same page would make a real disagreement hard to
 * diagnose.
 *
 * The algorithm is the Ratcliff/Obershelp style used by difflib: find the
 * longest matching block, then recurse on what is left of it and what is right
 * of it.
 */

export type OpcodeTag = "equal" | "replace" | "delete" | "insert";

export interface Opcode {
  tag: OpcodeTag;
  aStart: number;
  aEnd: number;
  bStart: number;
  bEnd: number;
}

interface Match {
  a: number;
  b: number;
  size: number;
}

/**
 * Longest matching block within `a[aLow:aHigh]` and `b[bLow:bHigh]`.
 *
 * Ties go to the earliest position in `a`, then the earliest in `b`, which is
 * what makes the result deterministic and matches difflib.
 */
function findLongestMatch(
  a: readonly string[],
  b: readonly string[],
  b2j: Map<string, number[]>,
  aLow: number,
  aHigh: number,
  bLow: number,
  bHigh: number,
): Match {
  let bestI = aLow;
  let bestJ = bLow;
  let bestSize = 0;

  // `j2len[j]` is the length of the match ending at a[i-1], b[j-1].
  let j2len = new Map<number, number>();

  for (let i = aLow; i < aHigh; i += 1) {
    const newJ2len = new Map<number, number>();
    for (const j of b2j.get(a[i]!) ?? []) {
      if (j < bLow) continue;
      if (j >= bHigh) break;
      const length = (j2len.get(j - 1) ?? 0) + 1;
      newJ2len.set(j, length);
      if (length > bestSize) {
        bestI = i - length + 1;
        bestJ = j - length + 1;
        bestSize = length;
      }
    }
    j2len = newJ2len;
  }

  // difflib extends the block over equal elements at both ends. With no junk
  // these are already maximal, but they are kept so the port stays a faithful
  // translation rather than an argument about when they matter.
  while (bestI > aLow && bestJ > bLow && a[bestI - 1] === b[bestJ - 1]) {
    bestI -= 1;
    bestJ -= 1;
    bestSize += 1;
  }
  while (
    bestI + bestSize < aHigh &&
    bestJ + bestSize < bHigh &&
    a[bestI + bestSize] === b[bestJ + bestSize]
  ) {
    bestSize += 1;
  }

  return { a: bestI, b: bestJ, size: bestSize };
}

function matchingBlocks(a: readonly string[], b: readonly string[]): Match[] {
  const b2j = new Map<string, number[]>();
  b.forEach((element, index) => {
    const bucket = b2j.get(element);
    if (bucket) bucket.push(index);
    else b2j.set(element, [index]);
  });

  const queue: Array<[number, number, number, number]> = [[0, a.length, 0, b.length]];
  const found: Match[] = [];

  while (queue.length) {
    const [aLow, aHigh, bLow, bHigh] = queue.pop()!;
    const match = findLongestMatch(a, b, b2j, aLow, aHigh, bLow, bHigh);
    if (match.size === 0) continue;
    found.push(match);
    if (aLow < match.a && bLow < match.b) {
      queue.push([aLow, match.a, bLow, match.b]);
    }
    if (match.a + match.size < aHigh && match.b + match.size < bHigh) {
      queue.push([match.a + match.size, aHigh, match.b + match.size, bHigh]);
    }
  }

  found.sort((x, y) => x.a - y.a || x.b - y.b);

  // Collapse adjacent blocks into one, exactly as difflib does before
  // returning; without this the opcodes would carry spurious zero-length
  // `equal` runs.
  const merged: Match[] = [];
  let a1 = 0;
  let b1 = 0;
  let size1 = 0;
  for (const { a: a2, b: b2, size: size2 } of found) {
    if (a1 + size1 === a2 && b1 + size1 === b2) {
      size1 += size2;
    } else {
      if (size1) merged.push({ a: a1, b: b1, size: size1 });
      a1 = a2;
      b1 = b2;
      size1 = size2;
    }
  }
  if (size1) merged.push({ a: a1, b: b1, size: size1 });

  // Sentinel terminator, as difflib appends.
  merged.push({ a: a.length, b: b.length, size: 0 });
  return merged;
}

/** Opcodes describing how to turn `a` into `b`. */
export function getOpcodes(a: readonly string[], b: readonly string[]): Opcode[] {
  let i = 0;
  let j = 0;
  const opcodes: Opcode[] = [];

  for (const block of matchingBlocks(a, b)) {
    let tag: OpcodeTag | null = null;
    if (i < block.a && j < block.b) tag = "replace";
    else if (i < block.a) tag = "delete";
    else if (j < block.b) tag = "insert";

    if (tag) {
      opcodes.push({ tag, aStart: i, aEnd: block.a, bStart: j, bEnd: block.b });
    }

    i = block.a + block.size;
    j = block.b + block.size;
    if (block.size) {
      opcodes.push({
        tag: "equal",
        aStart: block.a,
        aEnd: i,
        bStart: block.b,
        bEnd: j,
      });
    }
  }

  return opcodes;
}
