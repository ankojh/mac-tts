import unittest

from hush_tts.text import MAX_CHUNK, prepare


class ReadingCleanupTests(unittest.TestCase):
    def spoken(self, text, **kwargs):
        return [s["text"] for s in prepare(text, **kwargs)["segments"]]

    def test_markdown_bullets_and_links(self):
        result = prepare("# A title\n- **First** idea.\n2. [Second idea](https://example.com).\n- [x] Finished")
        self.assertEqual([s["text"] for s in result["segments"]], ["A title", "First idea.", "Second idea.", "Finished"])
        self.assertEqual([s["kind"] for s in result["segments"]], ["heading", "bullet", "bullet", "bullet"])

    def test_conservative_noise(self):
        source = "Skip to content\nAdvertisement\nThe word advertisement is part of this sentence.\nNo\n42\nSubscribe\nKeep this."
        self.assertEqual(self.spoken(source), ["The word advertisement is part of this sentence.", "No", "42", "Keep this."])
        self.assertIn("Subscribe", self.spoken(source, clean=False))

    def test_code_fences_can_be_kept(self):
        source = "Before.\n```python\nprint('hello')\n```\nAfter."
        self.assertEqual(self.spoken(source), ["Before.", "After."])
        self.assertTrue(any("print" in t for t in self.spoken(source, clean=False)))

    def test_abbreviations_decimal_and_sentences(self):
        self.assertEqual(self.spoken("Dr. Smith paid $3.50 today. Next question? Yes!"),
                         ["Dr. Smith paid $3.50 today.", "Next question?", "Yes!"])

    def test_utf16_mapping_after_emoji_and_formatting(self):
        source = "🎧 Intro.\n• **Café** is ready.\nNext."
        result = prepare(source)
        encoded = source.encode("utf-16-le")
        spans = [encoded[s["start"] * 2:s["end"] * 2].decode("utf-16-le") for s in result["segments"]]
        self.assertEqual(spans, ["Intro.", "Café** is ready.", "Next."])

    def test_long_text_is_bounded_without_loss(self):
        source = " ".join(["long" for _ in range(800)])
        chunks = self.spoken(source)
        self.assertTrue(all(len(chunk) <= MAX_CHUNK for chunk in chunks))
        self.assertEqual(" ".join(chunks), source)

    def test_tables_keep_values_in_order(self):
        self.assertEqual(self.spoken("| Name | Score |\n|---|---|\n| Ada | 42 |"), ["Name ; Score", "Ada ; 42"])

    def test_urls_and_citations(self):
        self.assertEqual(self.spoken("Useful claim [12]. See https://example.com for more."), ["Useful claim .", "See for more."])

    def test_no_readable_text(self):
        self.assertEqual(prepare("\n---\n🎉🎧\n")["segments"], [])

    def test_reference_annotations(self):
        self.assertEqual(self.spoken("Claim¹² and result₃ agree[1, 2–4]. Next† fact[^note]."),
                         ["Claim and result agree.", "Next fact."])
        self.assertEqual(self.spoken("Claim[12](#ref12) holds<sup>7</sup>.\n[^note]: Footnote body"), ["Claim holds."])
        self.assertEqual(self.spoken("Keep 2026, 3.5 and 42."), ["Keep 2026, 3.5 and 42."])
        self.assertEqual(self.spoken("Claim¹ and value₂.", clean=False), ["Claim¹ and value₂."])

    def test_word_offsets_survive_citation_cleanup(self):
        source = "🎧 **Hello**¹ world[12]. Next₃ word."
        result = prepare(source)
        raw = source.encode("utf-16-le")
        words = [raw[w["start"] * 2:w["end"] * 2].decode("utf-16-le")
                 for s in result["segments"] for w in s["words"]]
        self.assertEqual(words, ["Hello", "world[12].", "Next", "word."])

    def test_invalid_or_oversized_input(self):
        for text in [None, 123, "a" * 100001]:
            with self.assertRaises(ValueError):
                prepare(text)

    def test_source_ranges_are_monotonic(self):
        source = "# 日本語 title\n* First 😃 sentence. Another **sentence**.\n\n2. Third item.\n"
        segments = prepare(source)["segments"]
        for previous, following in zip(segments, segments[1:]):
            self.assertLessEqual(previous["end"], following["start"])
        self.assertTrue(all(s["end"] > s["start"] for s in segments))

    def test_content_is_not_deduplicated(self):
        self.assertEqual(self.spoken("Yes.\nYes."), ["Yes.", "Yes."])

    def test_soft_wrapped_prose_and_bullet_continuation(self):
        source = "This is a long line from a document which wraps\nonto the next line naturally.\n\n- A list item that\n  continues here.\n- Next item."
        self.assertEqual(self.spoken(source), ["This is a long line from a document which wraps onto the next line naturally.",
                                               "A list item that continues here.", "Next item."])


if __name__ == "__main__":
    unittest.main()
