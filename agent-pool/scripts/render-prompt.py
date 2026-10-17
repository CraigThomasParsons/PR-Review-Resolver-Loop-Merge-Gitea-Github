#!/usr/bin/env python3
"""render-prompt.py TEMPLATE OUT KEY=VALUE...

Replace every __KEY__ in TEMPLATE with VALUE and write OUT. Plain str.replace: branch names
and paths may contain |, &, \\ or anything else a sed replacement would interpret.
"""
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    template, out = sys.argv[1], sys.argv[2]
    text = open(template).read()
    for pair in sys.argv[3:]:
        key, sep, value = pair.partition("=")
        if not sep:
            sys.exit(f"render-prompt: expected KEY=VALUE, got {pair!r}")
        text = text.replace(f"__{key}__", value)
    with open(out, "w") as f:
        f.write(text)


if __name__ == "__main__":
    main()
