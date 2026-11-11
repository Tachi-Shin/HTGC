"""Report pixel differences for screenshots of the same client area and state."""

import argparse
import json

from PIL import Image, ImageChops


def compare(reference, actual, tolerance=0):
    with Image.open(reference) as image:
        expected = image.convert("RGB")
    with Image.open(actual) as image:
        observed = image.convert("RGB")
    if expected.size != observed.size:
        raise ValueError(f"画像サイズが異なります: {expected.size} と {observed.size}")
    difference = ImageChops.difference(expected, observed)
    red, green, blue = difference.split()
    maximum = ImageChops.lighter(ImageChops.lighter(red, green), blue)
    count = sum(maximum.histogram()[tolerance + 1 :])
    pixels = expected.width * expected.height
    error = sum((value % 256) * n for value, n in enumerate(difference.histogram()))
    return difference, {
        "size": list(expected.size),
        "channel_tolerance": tolerance,
        "different_pixels": count,
        "total_pixels": pixels,
        "different_percent": round(count * 100 / pixels, 4),
        "mean_absolute_rgb_error": round(error / (pixels * 3), 4),
        "max_channel_error": maximum.getextrema()[1],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    parser.add_argument("actual")
    parser.add_argument("--diff")
    parser.add_argument("--channel-tolerance", type=int, default=0)
    parser.add_argument("--max-different-pixels", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.channel_tolerance <= 255 or args.max_different_pixels < 0:
        parser.error("許容値が範囲外です")
    try:
        difference, report = compare(
            args.reference, args.actual, args.channel_tolerance
        )
    except (OSError, ValueError) as error:
        parser.exit(2, f"{error}\n")
    if args.diff:
        difference.save(args.diff)
    print(json.dumps(report, ensure_ascii=False))
    return int(report["different_pixels"] > args.max_different_pixels)


if __name__ == "__main__":
    raise SystemExit(main())
