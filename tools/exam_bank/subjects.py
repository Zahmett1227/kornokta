"""A7's deterministic half — the subject order ÖSYM prints (§5.10).

Every test sets its subjects in one fixed order, a block each. The model's
per-question label is a vote; the subject a question finally gets is the one
from the **monotone segmentation** — the split of the paper into consecutive
blocks, in the paper's subject order, that agrees with the most votes. One
wrong vote inside a block is outvoted by its neighbours and corrected; a
paper whose votes do not follow the order at all is reported and left to the
votes (the order in the registry, not the model, would then be what is wrong).

ÖSYM subject names → the app's canonical subjects (Ek C): Histoloji-
Embriyoloji lives under the app's Fizyoloji (whose topics carry the
"HistoFizyolojisi" and embryology entries); the original name is kept as
`osymSubject` and shown as such.
"""
from __future__ import annotations

from typing import Dict, List, Optional, Sequence, Tuple

TEMEL = ["Anatomi", "Histoloji-Embriyoloji", "Fizyoloji", "Biyokimya", "Mikrobiyoloji", "Patoloji",
         "Farmakoloji"]
KLINIK = ["Dahiliye", "Pediatri", "Genel Cerrahi", "Kadın Hastalıkları ve Doğum", "Küçük Stajlar"]
OSYM_SUBJECTS = TEMEL + KLINIK

# The Klinik test's blocks as printed, measured on the model's votes for
# every Klinik paper 2006–2026 and on the 2026 analysis's 932 labels: the
# minor specialties come twice — the medical ones (neurology, psychiatry,
# dermatology …) after Dahiliye, the surgical ones (urology, orthopaedics,
# ENT …) after Genel Cerrahi. 2006–2008 booklets head the test "İç
# Hastalıkları, Pediatri, Cerrahi, Kadın-Doğum", but their questions sit in
# the same six blocks; labelling them the same way keeps a subject filter
# meaning the same thing across years.
KLINIK_ORDER = ["Dahiliye", "Küçük Stajlar", "Pediatri", "Genel Cerrahi", "Küçük Stajlar",
                "Kadın Hastalıkları ve Doğum"]

TO_APP = {
    "Anatomi": "Anatomi",
    "Histoloji-Embriyoloji": "Fizyoloji",
    "Fizyoloji": "Fizyoloji",
    "Biyokimya": "Biyokimya",
    "Mikrobiyoloji": "Mikrobiyoloji",
    "Patoloji": "Patoloji",
    "Farmakoloji": "Farmakoloji",
    "Dahiliye": "Dahiliye",
    "Pediatri": "Pediatri",
    "Genel Cerrahi": "Genel Cerrahi",
    "Kadın Hastalıkları ve Doğum": "Kadın Hastalıkları ve Doğum",
    "Küçük Stajlar": "Küçük Stajlar",
}

# Below this share of votes kept, the order does not describe the paper —
# judged only on papers with enough questions to say so. ÖSYM's partial
# booklets show ~12 questions, one or two per block, where a single wrong
# vote moves agreement by 8 points; there the known order is trusted over
# the votes (2022/1 Klinik: 7 of 12 votes kept, and the segmentation agrees
# with the 2026 analysis's labels on 10 of 12).
MIN_AGREEMENT = 0.75
SPARSE = 30


def order_for(test: str, votes: Sequence[Optional[str]] = ()) -> List[str]:
    """T: the seven Temel subjects. K: the six Klinik blocks. T2 — the extra
    Temel test of 2011/1 and 2012/1 — has no fixed order (2012/1 sets
    Biyokimya before Mikrobiyoloji, 2011/1 the reverse), so its order is
    read off the votes: subjects by the median position of their votes."""
    if test == "T":
        return list(TEMEL)
    if test == "K":
        return list(KLINIK_ORDER)
    positions: Dict[str, List[int]] = {}
    for i, v in enumerate(votes):
        if v:
            positions.setdefault(v, []).append(i)
    return sorted(positions, key=lambda s: sorted(positions[s])[len(positions[s]) // 2])


def segment(votes: Sequence[Optional[str]], order: Sequence[str]) -> Tuple[List[str], int]:
    """Monotone labels for `votes` (None = no vote), and how many votes they
    keep. Dynamic programme over (question, block): each question takes the
    same block as the one before or a later one in `order`. Blocks may be
    skipped (a paper can lack one) but never revisited; a subject may head
    more than one block (Klinik's two Küçük Stajlar blocks)."""
    n, k = len(votes), len(order)
    if n == 0 or k == 0:
        return [v or "" for v in votes], 0
    neg = -1
    score = [[neg] * k for _ in range(n)]
    back = [[0] * k for _ in range(n)]
    for j in range(k):
        score[0][j] = int(votes[0] == order[j])
    for i in range(1, n):
        best_prev, arg = neg, 0
        for j in range(k):
            if score[i - 1][j] > best_prev:
                best_prev, arg = score[i - 1][j], j
            score[i][j] = best_prev + int(votes[i] == order[j])
            back[i][j] = arg
    j = max(range(k), key=lambda j: (score[n - 1][j], -j))
    kept = score[n - 1][j]
    labels = [""] * n
    for i in range(n - 1, -1, -1):
        labels[i] = order[j]
        j = back[i][j]
    return labels, kept


def settle(votes: Sequence[Optional[str]], test: str, year: int = 0) -> Dict[str, object]:
    """The subjects a paper's questions get, with the evidence for them."""
    order = order_for(test, votes)
    labels, kept = segment(votes, order)
    cast = sum(1 for v in votes if v is not None)
    agreement = kept / cast if cast else 0.0
    sparse = cast < SPARSE
    if cast and agreement < MIN_AGREEMENT and not sparse:
        # A full paper whose votes do not follow the order: the order, not
        # the model, is what is in doubt. Keep the votes, report the paper.
        return {"labels": [v or "" for v in votes], "monotone": False, "agreement": agreement,
                "corrected": 0, "sparse": sparse}
    corrected = sum(1 for v, l in zip(votes, labels) if v is not None and v != l)
    return {"labels": labels, "monotone": True, "agreement": agreement, "corrected": corrected,
            "sparse": sparse}
