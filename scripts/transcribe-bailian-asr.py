#!/usr/bin/env python3
import argparse
import json
import os
import sys
import time
import wave


def progress(message):
    print(f"PROGRESS {message}", file=sys.stderr, flush=True)


def result_to_dict(result):
    if isinstance(result, dict):
        return dict(result)
    to_dict = getattr(type(result), "to_dict", None)
    if callable(to_dict):
        try:
            return to_dict(result)
        except Exception:
            pass
    keys = getattr(type(result), "keys", None)
    if callable(keys):
        try:
            return {key: result[key] for key in result.keys()}
        except Exception:
            pass
    try:
        return dict(result)
    except Exception:
        pass
    return {}


def extract_text_and_segments(result, chunk_index):
    data = result_to_dict(result)
    status_code = data.get("status_code") if isinstance(data, dict) else None
    if status_code not in (None, 200):
        code = data.get("code") or "unknown_error"
        message = data.get("message") or "Bailian ASR request failed"
        raise RuntimeError(f"Bailian ASR failed ({status_code}, {code}): {message}")

    candidates = []

    sentence = getattr(result, "get_sentence", None)
    if callable(sentence):
        try:
            candidates.append(sentence())
        except Exception:
            pass

    output = data.get("output") if isinstance(data, dict) else None
    if isinstance(output, dict):
        for key in ("sentence", "text"):
            if isinstance(output.get(key), str):
                candidates.append(output[key])
        sentence_items = None
        if isinstance(output.get("sentence"), list):
            sentence_items = output["sentence"]
        elif isinstance(output.get("sentences"), list):
            sentence_items = output["sentences"]

        if sentence_items:
            segments = []
            parts = []
            for index, item in enumerate(sentence_items):
                if not isinstance(item, dict):
                    continue
                text = str(item.get("text") or item.get("sentence") or "").strip()
                if not text:
                    continue
                parts.append(text)
                begin = item.get("begin_time") or item.get("start_time") or item.get("start")
                end = item.get("end_time") or item.get("end")
                segments.append(
                    {
                        "id": f"bailian-{chunk_index}-{index}",
                        "start": milliseconds_to_seconds(begin),
                        "end": milliseconds_to_seconds(end),
                        "speaker": speaker_value(item),
                        "text": text,
                    }
                )
            if parts:
                return "\n".join(parts), segments

    text = next((item.strip() for item in candidates if isinstance(item, str) and item.strip()), "")
    if not text and isinstance(data, dict):
        text = json.dumps(data, ensure_ascii=False)
    segment = {
        "id": f"bailian-{chunk_index}-0",
        "start": None,
        "end": None,
        "speaker": None,
        "text": text,
    }
    return text, [segment] if text else []


def offset_segments(segments, offset):
    if not offset:
        return segments
    shifted = []
    for segment in segments:
        item = dict(segment)
        if item.get("start") is not None:
            item["start"] = item["start"] + offset
        if item.get("end") is not None:
            item["end"] = item["end"] + offset
        shifted.append(item)
    return shifted


def wav_duration(path):
    try:
        with wave.open(path, "rb") as audio:
            frames = audio.getnframes()
            rate = audio.getframerate()
            return frames / float(rate) if rate else 0
    except Exception:
        return 0


def milliseconds_to_seconds(value):
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number / 1000.0 if number > 1000 else number


def speaker_value(item):
    value = item.get("speaker") or item.get("speaker_id")
    return None if value is None else str(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="paraformer-realtime-v2")
    parser.add_argument("audio_files", nargs="+")
    args = parser.parse_args()

    api_key = os.environ.get("DASHSCOPE_API_KEY")
    if not api_key:
        raise SystemExit("DASHSCOPE_API_KEY is not set")

    try:
        import dashscope
        from dashscope.audio.asr import Recognition
    except Exception as exc:
        raise SystemExit(f"dashscope SDK is not installed or could not be imported: {exc}")

    dashscope.api_key = api_key
    all_text = []
    all_segments = []
    offset = 0.0

    for chunk_index, path in enumerate(args.audio_files):
        progress(f"Bailian ASR transcribing chunk {chunk_index + 1}/{len(args.audio_files)}")
        recognition = Recognition(
            model=args.model,
            format="wav",
            sample_rate=16000,
            language_hints=["zh", "en"],
            callback=None,
        )
        result = recognition.call(path)
        text, segments = extract_text_and_segments(result, chunk_index)
        if not text:
            raise SystemExit(f"Bailian ASR returned empty transcript for {path}")
        all_text.append(text)
        all_segments.extend(offset_segments(segments, offset))
        offset += wav_duration(path)
        time.sleep(0.2)

    print(
        json.dumps(
            {
                "text": "\n\n".join(all_text),
                "segments": all_segments,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
