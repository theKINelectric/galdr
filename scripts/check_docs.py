#!/usr/bin/env python3
"""Every ```odin block in a checked doc must appear verbatim in the example
package that backs it, so documented code always compiles and is tested.
A block may elide with a line that is exactly `// ...` (after indentation):
each part between elisions is checked on its own."""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BACKING = {
    'README.md': 'examples/readme',
    'docs/TUTORIAL.md': 'examples/tutorial',
    'docs/COOKBOOK.md': 'examples/cookbook',
}

failures = 0
for doc, pkg in BACKING.items():
    doc_path, pkg_path = ROOT / doc, ROOT / pkg
    if not doc_path.exists():
        continue
    source = '\n'.join(p.read_text() for p in sorted(pkg_path.glob('*.odin')))
    blocks = re.findall(r'```odin\n(.*?)```', doc_path.read_text(), re.S)
    before = failures
    for n, block in enumerate(blocks, 1):
        parts = re.split(r'^[ \t]*// \.\.\.[ \t]*\n', block, flags=re.M)
        for part in parts:
            if part.strip() and part.rstrip('\n') not in source:
                failures += 1
                first = part.strip().splitlines()[0]
                print(f'{doc}: odin block {n} is not in {pkg}/: {first!r}')
    if failures == before:
        print(f'ok   {doc}: {len(blocks)} odin blocks match {pkg}/')

sys.exit(1 if failures else 0)
