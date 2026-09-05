import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "bailian", Path(__file__).parents[1] / "scripts" / "transcribe-bailian-asr.py"
)
bailian = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bailian)


class BailianResultTests(unittest.TestCase):
    def test_milliseconds_including_first_second_and_zero(self):
        result = {"status_code": 200, "output": {"sentence": [
            {"text": "Hello", "begin_time": 0, "end_time": 500, "speaker_id": 0},
            {"text": "World", "begin_time": 1000, "end_time": 1500},
        ]}}
        text, segments = bailian.extract_text_and_segments(result, 0)
        self.assertEqual(text, "Hello\nWorld")
        self.assertEqual(segments[0]["start"], 0)
        self.assertEqual(segments[0]["end"], 0.5)
        self.assertEqual(segments[0]["speaker"], "0")
        self.assertEqual(segments[1]["start"], 1)

    def test_error_json_never_becomes_transcript(self):
        with self.assertRaises(RuntimeError):
            bailian.extract_text_and_segments({"status_code": 401, "message": "Unauthorized"}, 0)
        self.assertEqual(bailian.extract_text_and_segments({"request_id": "abc"}, 0), ("", []))

    def test_non_streaming_sentence_method(self):
        class Result:
            def get_sentence(self):
                return [{"text": "Hello", "begin_time": 0, "end_time": 250}]
        _, segments = bailian.extract_text_and_segments(Result(), 0)
        self.assertEqual(segments[0]["end"], 0.25)

    def test_chunk_offsets_and_invalid_times(self):
        result = bailian.offset_segments([{"start": 0, "end": 0.5}], 600)
        self.assertEqual(result[0]["end"], 600.5)
        self.assertIsNone(bailian.milliseconds_to_seconds(float("nan")))
        self.assertIsNone(bailian.milliseconds_to_seconds(-1))


if __name__ == "__main__":
    unittest.main()
