import unittest
from types import SimpleNamespace
from unittest.mock import patch
from hush_tts.alignment import align_words


class WordAlignmentTests(unittest.TestCase):
    def timings(self, phonemes):
        return [SimpleNamespace(phoneme=p, start=i * .1, end=(i + 1) * .1) for i, p in enumerate(phonemes)]

    def align(self, text, sounds, pronunciations):
        with patch('phonemizer.phonemize', return_value=pronunciations):
            return align_words(text, self.timings(sounds), SimpleNamespace(known=lambda x: x), 'en-us')

    def test_expanded_number_maps_to_one_written_word(self):
        result = self.align('12 cats', 'twɛlv kæts', ['twɛlv', 'kæts'])
        self.assertEqual([w['index'] for w in result], [0, 1])
        self.assertAlmostEqual(result[0]['end'], .5)
        self.assertAlmostEqual(result[1]['start'], .6)

    def test_unmatched_pronunciation_does_not_get_invented_timing(self):
        result = self.align('a cat', 'ə kæt', ['eɪ', 'kæt'])
        self.assertEqual([w['index'] for w in result], [1])

    def test_repeated_words_stay_in_order(self):
        result = self.align('yes yes', 'jɛs jɛs', ['jɛs', 'jɛs'])
        self.assertEqual([w['index'] for w in result], [0, 1])
        self.assertLess(result[0]['end'], result[1]['start'])

    def test_missing_model_timings_remain_empty(self):
        self.assertEqual(align_words('hello', [], None, 'en-us'), [])
