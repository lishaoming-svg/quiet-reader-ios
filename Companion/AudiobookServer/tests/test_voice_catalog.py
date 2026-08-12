import sys
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from voice_catalog import (
    approved_voices,
    load_voice_catalog,
    public_voice_options,
    resolve_audio_path,
    stable_character_voice,
)


class VoiceCatalogTests(unittest.TestCase):
    def test_all_confirmed_voices_and_audio_are_present(self):
        catalog = load_voice_catalog()
        voices = catalog["voices"]

        self.assertEqual(len(voices), 11)
        self.assertEqual(
            Counter(voice["group"] for voice in voices),
            {"narrator": 1, "male": 5, "female": 5},
        )
        for voice in voices:
            self.assertTrue(resolve_audio_path(voice["preview_audio"]).is_file())

    def test_default_roles_reference_confirmed_voices(self):
        catalog = load_voice_catalog()
        voice_ids = {voice["id"] for voice in catalog["voices"]}

        self.assertEqual(
            set(catalog["default_assignment"]),
            {
                "narrator",
                "protagonist_male",
                "protagonist_female",
                "male_supporting",
                "female_supporting",
            },
        )
        self.assertTrue(set(catalog["default_assignment"].values()) <= voice_ids)

    def test_group_filter_returns_only_requested_group(self):
        female_voices = approved_voices("female")

        self.assertEqual(len(female_voices), 5)
        self.assertTrue(all(voice["gender"] == "female" for voice in female_voices))

    def test_public_options_include_automatic_and_all_single_voices(self):
        options = public_voice_options()

        self.assertEqual(options[0]["id"], "multi-role")
        self.assertEqual(len(options), 12)
        self.assertTrue(all("group" in option for option in options))

    def test_named_character_keeps_stable_voice(self):
        first = stable_character_voice("何雁", "female", "female")
        second = stable_character_voice("何雁", "female", "protagonist")

        self.assertEqual(first, second)
        self.assertIn(first, {voice["id"] for voice in approved_voices("female")})


if __name__ == "__main__":
    unittest.main()
