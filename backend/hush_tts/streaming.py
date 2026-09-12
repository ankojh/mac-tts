"""Incremental PCM synthesis with phonetic context on both sides of each chunk.

The ONNX graph is not autoregressive: it renders a short window at a time.
Only that window and a 10 ms join tail are retained, never a document WAV.
"""
import base64
import numpy as np
from kokoro_onnx.sliding import Timing, token_edges
from .alignment import align_words

RATE = 24000


def stream(model, text, voice, lang):
    phonemes = model.tokenizer.phonemize(text, lang)
    phonemes = model.tokenizer.known(' '.join(phonemes.split()))
    tokens = model.tokenizer.tokenize(phonemes, limit=None)
    if not tokens:
        raise ValueError('No pronounceable text in this passage.')
    # Align once for the entire context, not once for every audio buffer.
    alignment = align_words(text, [Timing(p, i, i + 1) for i, p in enumerate(phonemes)], model.tokenizer, lang)
    style = model._style_for(model.get_voice_style(voice), len(tokens))
    start, emitted = 0, 0
    tail = np.empty(0, dtype=np.float32)
    while start < len(tokens):
        keep = 120 if start == 0 else 240
        target = min(start + keep, len(tokens))
        end = target
        if target < len(tokens):
            candidates = [i for i in range(max(start + 30, target - 24), min(len(tokens), target + 24))
                          if phonemes[i].isspace()]
            if candidates:
                end = min(candidates, key=lambda i: abs(i - target))
        first, last = max(0, start - 48), min(len(tokens), end + 64)
        samples, durations = model._infer(tokens[first:last], style, 1.0)
        if durations is None:
            raise RuntimeError('This model needs phoneme durations for streaming.')
        edges = token_edges(durations, len(samples))
        begin, finish = int(edges[start - first + 1]), int(edges[end - first + 1])
        piece = np.asarray(samples[begin:finish], dtype=np.float32)
        if not len(piece) or not np.isfinite(piece).all():
            raise RuntimeError('The model returned invalid streaming audio.')
        # Overlap only at a word gap. Timings use the exact same sample offsets.
        overlap = min(len(tail), len(piece), RATE // 100)
        base = emitted + len(tail) - overlap
        if overlap:
            fade = np.linspace(0, 1, overlap, dtype=np.float32)
            output = np.concatenate([tail[:-overlap], tail[-overlap:] * (1 - fade) + piece[:overlap] * fade, piece[overlap:]])
        else:
            output = np.concatenate([tail, piece])
        words = []
        for word in alignment:
            a, b = int(word['start']), int(word['end'])
            if start <= a < b <= end:
                words.append({'index': word['index'],
                              'start': (base + int(edges[a - first + 1]) - begin) / RATE,
                              'end': (base + int(edges[b - first + 1]) - begin) / RATE})
        final = end == len(tokens)
        hold = 0 if final else min(RATE // 100, max(0, len(output) - 1))
        tail = output[-hold:].copy() if hold else np.empty(0, dtype=np.float32)
        output = output[:-hold] if hold else output
        emitted += len(output)
        yield {'pcm': base64.b64encode(np.clip(output, -1, 1).astype('<f4').tobytes()).decode('ascii'),
               'rate': RATE, 'words': words, 'duration': len(output) / RATE, 'done': final}
        start = end
