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

# Below this share of votes kept, the order does not describe the paper.
MIN_AGREEMENT = 0.75


def order_for(test: str, year: int) -> List[str]:
    """T and T2 are Temel tests; 2006–2008 Klinik has no Küçük Stajlar (its
    booklet lists "İç Hastalıkları, Pediatri, Cerrahi, Kadın-Doğum")."""
    if test in ("T", "T2"):
        return list(TEMEL)
    return KLINIK[:4] if year <= 2008 else list(KLINIK)


def segment(votes: Sequence[Optional[str]], order: Sequence[str]) -> Tuple[List[str], int]:
    """Monotone labels for `votes` (None = no vote), and how many votes they
    keep. Dynamic programme over (question, subject index): each question
    takes the same subject as the one before or a later one in `order`.
    Subjects may be skipped (a paper can lack a block) but never revisited."""
    n, k = len(votes), len(order)
    if n == 0:
        return [], 0
    index = {s: i for i, s in enumerate(order)}
    neg = -1
    score = [[neg] * k for _ in range(n)]
    back = [[0] * k for _ in range(n)]
    for j in range(k):
        score[0][j] = int(index.get(votes[0]) == j)
    for i in range(1, n):
        gain = [int(index.get(votes[i]) == j) for j in range(k)]
        best_prev, arg = neg, 0
        for j in range(k):
            if score[i - 1][j] > best_prev:
                best_prev, arg = score[i - 1][j], j
            score[i][j] = best_prev + gain[j]
            back[i][j] = arg
    j = max(range(k), key=lambda j: (score[n - 1][j], -j))
    kept = score[n - 1][j]
    labels = [""] * n
    for i in range(n - 1, -1, -1):
        labels[i] = order[j]
        j = back[i][j]
    return labels, kept


def settle(votes: Sequence[Optional[str]], test: str, year: int) -> Dict[str, object]:
    """The subjects a paper's questions get, with the evidence for them."""
    order = order_for(test, year)
    labels, kept = segment(votes, order)
    cast = sum(1 for v in votes if v is not None)
    agreement = kept / cast if cast else 0.0
    if cast and agreement < MIN_AGREEMENT:
        # The order does not fit: keep the votes, report the paper.
        return {"labels": [v or "" for v in votes], "monotone": False, "agreement": agreement,
                "corrected": 0}
    corrected = sum(1 for v, l in zip(votes, labels) if v is not None and v != l)
    return {"labels": labels, "monotone": True, "agreement": agreement, "corrected": corrected}
