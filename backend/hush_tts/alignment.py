"""Map model phoneme timestamps to written words, without estimating speech speed."""
from difflib import SequenceMatcher
import re
import unicodedata


def word_matches(text):
    return [m for m in re.finditer(r"\S+", text) if any(c.isalnum() for c in m.group())]


def sound(char):
    return char not in "ˈˌ" and (char.isalpha() or unicodedata.category(char).startswith("M"))


def align_words(text, timings, tokenizer, lang):
    if not timings:
        return []
    # Phonemize all written tokens in one call, including number expansions.
    # The synthesized sentence itself retains its original contextual pronunciation.
    import phonemizer
    from kokoro_onnx.tokenizer import _espeak_lock
    words = word_matches(text)
    with _espeak_lock:
        pronunciations = phonemizer.phonemize([m.group() for m in words], lang,
                                             preserve_punctuation=True, with_stress=True)
    expected, owners = [], []
    for index, pronunciation in enumerate(pronunciations):
        for char in tokenizer.known(pronunciation):
            if sound(char):
                expected.append(char)
                owners.append(index)
    actual = [t for t in timings if sound(t.phoneme)]
    projection = {}
    for block in SequenceMatcher(None, expected, [t.phoneme for t in actual], autojunk=False).get_matching_blocks():
        for offset in range(block.size):
            projection[block.a + offset] = block.b + offset
    result = []
    for index in range(len(words)):
        positions = [p for p, owner in enumerate(owners) if owner == index]
        mapped = [projection[p] for p in positions if p in projection]
        # A contextual pronunciation that cannot be matched keeps sentence-only
        # highlighting. Never invent a duration from the number of characters.
        if not positions or len(mapped) != len(positions) or mapped != list(range(mapped[0], mapped[-1] + 1)):
            continue
        start, end = actual[mapped[0]].start, actual[mapped[-1]].end
        if end > start:
            result.append({"index": index, "start": start, "end": end})
    return result
