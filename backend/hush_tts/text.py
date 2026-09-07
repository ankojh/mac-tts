"""Conservative reading cleanup with exact UTF-16 offsets back into source text.

We never ask an LLM to rewrite the user's content. Every spoken character carries
its source offset, even after Markdown cleanup, so Cocoa ranges remain correct.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from .alignment import word_matches

MAX_TEXT = 100_000
MAX_CHUNK = 260
NOISE = re.compile(
    r"^(?:skip to (?:main )?content|accept (?:all )?cookies|reject (?:all )?cookies|"
    r"manage (?:cookies|preferences)|cookie (?:settings|policy)|advertisement|"
    r"share (?:this|on .+)|copy link|sign (?:in|up)|log in|subscribe|"
    r"all rights reserved\.?|privacy policy|terms (?:of (?:use|service))|"
    r"loading[. …]*|menu|navigation)$", re.I,
)
ABBREVIATIONS = {"mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "fig", "no"}


@dataclass
class Segment:
    id: int
    text: str
    start: int  # UTF-16 offset in the unmodified input
    end: int
    kind: str
    words: list[dict]


def _sub(chars: list[tuple[str, int]], pattern: str, group: int | None = None) -> list[tuple[str, int]]:
    text = "".join(c for c, _ in chars)
    output = []
    last = 0
    for match in re.finditer(pattern, text):
        output.extend(chars[last:match.start()])
        if group is not None:
            output.extend(chars[match.start(group):match.end(group)])
        last = match.end()
    return output + chars[last:]


def _trim(chars: list[tuple[str, int]]) -> list[tuple[str, int]]:
    while chars and chars[0][0].isspace():
        chars = chars[1:]
    while chars and chars[-1][0].isspace():
        chars = chars[:-1]
    return chars


def _chunks(chars: list[tuple[str, int]]):
    text = "".join(c for c, _ in chars)
    start = 0
    for match in re.finditer(r'[.!?]+[”’"\)]*(?:\s+|$)', text):
        before = text[:match.start()]
        token = re.search(r"([\w.]+)$", before)
        word = token.group(1).lower() if token else ""
        if text[match.start()] == "." and (word in ABBREVIATIONS or re.fullmatch(r"(?:[a-z]\.)*[a-z]", word)):
            continue
        end = match.end()
        yield from _bounded(chars[start:end])
        start = end
    yield from _bounded(chars[start:])


def _bounded(chars: list[tuple[str, int]]):
    chars = _trim(chars)
    while len(chars) > MAX_CHUNK:
        text = "".join(c for c, _ in chars)
        # Prefer a clause boundary, then whitespace; cap even unbroken input.
        cuts = [m.end() for m in re.finditer(r"[,;:]\s", text[:MAX_CHUNK + 1]) if m.end() > 80]
        cut = cuts[-1] if cuts else text.rfind(" ", 0, MAX_CHUNK + 1)
        if cut < 1:
            cut = MAX_CHUNK
        yield _trim(chars[:cut])
        chars = _trim(chars[cut:])
    if chars:
        yield chars


def prepare(text: str, clean: bool = True) -> dict:
    if not isinstance(text, str) or len(text) > MAX_TEXT:
        raise ValueError(f"Read up to {MAX_TEXT:,} characters at a time.")
    # A single linear pass avoids quadratic UTF-16 conversions on long articles.
    offsets = [0]
    for char in text:
        offsets.append(offsets[-1] + (2 if ord(char) > 0xFFFF else 1))
    segments: list[Segment] = []
    skipped = 0
    source_index = 0
    fence = None
    pending: list[tuple[str, int]] = []
    pending_kind = "paragraph"

    def flush():
        nonlocal pending
        for chunk in _chunks(pending):
            if chunk:
                spoken = "".join(c for c, _ in chunk)
                words = [{"start": offsets[chunk[m.start()][1]],
                          "end": offsets[chunk[m.end() - 1][1] + 1]} for m in word_matches(spoken)]
                segments.append(Segment(len(segments), spoken,
                                        offsets[chunk[0][1]], offsets[chunk[-1][1] + 1], pending_kind, words))
        pending = []

    for raw in text.splitlines(keepends=True):
        chars = [(c, source_index + i) for i, c in enumerate(raw)]
        source_index += len(raw)
        line = raw.strip()
        if not line:
            flush()
            continue
        fence_match = re.match(r"^(`{3,}|~{3,})", line)
        if clean and fence_match:
            flush()
            marker = fence_match.group(1)[0]
            fence = None if fence == marker else marker if fence is None else fence
            skipped += 1
            continue
        if clean and (fence or NOISE.fullmatch(line) or re.fullmatch(r"[\s|:*-]+", line)):
            flush()
            skipped += 1
            continue
        if clean and re.match(r"^\s*\[\^[^\]]+\]:", raw):
            flush()
            skipped += 1
            continue
        kind = "paragraph"
        if re.match(r"^\s*(?:[-*+•◦▪]|\d+[.)])\s+", raw):
            kind = "bullet"
        elif re.match(r"^\s*#{1,6}\s+", raw):
            kind = "heading"
        elif "|" in line and line.count("|") >= 2:
            kind = "table"
        chars = _sub(chars, r"^\s*(?:#{1,6}\s+|>\s*|(?:[-*+•◦▪]|\d+[.)])\s+(?:\[[ xX]\]\s*)?)")
        chars = _sub(chars, r"!\[[^\]]*\]\([^)]*\)")
        if clean:
            chars = _sub(chars, r"\[(?:\^[^\]]+|\s*\d+(?:\s*[,;–—-]\s*\d+)*\s*)\]\([^)]*\)")
            chars = _sub(chars, r"(?i)<(?:sup|sub)\b[^>]*>.*?</(?:sup|sub)\s*>")
        chars = _sub(chars, r"\[([^\]]+)\]\([^)]*\)", 1)
        chars = _sub(chars, r"(?:\*\*|__)(.+?)(?:\*\*|__)", 1)
        chars = _sub(chars, r"(?<!\w)[*_]([^*_\n]+)[*_](?!\w)", 1)
        chars = _sub(chars, r"`([^`]+)`", 1)
        if clean:
            chars = _sub(chars, r"https?://[^\s<>]+")
            chars = _sub(chars, r"\[\s*\d+(?:\s*[,;–—-]\s*\d+)*\s*\]")
            chars = _sub(chars, r"\[\^[^\]\n]+\]")
            # Unicode raised/lowered numeric reference markers, including ranges.
            chars = _sub(chars, r"[⁰¹²³⁴⁵⁶⁷⁸⁹₀₁₂₃₄₅₆₇₈₉]+(?:[,–—-][⁰¹²³⁴⁵⁶⁷⁸⁹₀₁₂₃₄₅₆₇₈₉]+)*")
            chars = _sub(chars, r"[†‡]+")
            # Remove zero-width controls and decorative emoji, keeping Unicode letters.
            chars = [(c, i) for c, i in chars if c not in "\u200b\u200c\u200d\ufeff\ufe0f" and not 0x1F000 <= ord(c) <= 0x1FAFF]
        if kind == "table":
            chars = _trim(chars)
            if chars and chars[0][0] == "|":
                chars = chars[1:]
            if chars and chars[-1][0] == "|":
                chars = chars[:-1]
            chars = [(";" if c == "|" else c, i) for c, i in chars]
        collapsed = []
        for c, i in chars:
            if c.isspace():
                if collapsed and collapsed[-1][0] != " ":
                    collapsed.append((" ", i))
            elif c.isprintable():
                collapsed.append((c, i))
        if not any(c.isalnum() for c, _ in collapsed):
            skipped += 1
            continue
        # Join soft-wrapped prose, preserving headings, list items and table rows.
        # A complete sentence or a short standalone label remains its own block.
        continuation = (kind == "paragraph" and pending and
                        pending_kind in {"paragraph", "bullet"} and
                        not re.search(r'[.!?:][”’"\)]*\s*$', "".join(c for c, _ in pending)) and
                        (len(pending) >= 45 or (pending_kind == "bullet" and raw[:1].isspace())))
        if continuation:
            if pending[-1][0] != " ":
                pending.append((" ", max(0, collapsed[0][1] - 1)))
            pending.extend(collapsed)
        else:
            flush()
            pending = collapsed
            pending_kind = kind
        if kind in {"heading", "table"}:
            flush()
    flush()
    return {"segments": [asdict(s) for s in segments], "skipped": skipped,
            "word_count": sum(len(s.text.split()) for s in segments)}
