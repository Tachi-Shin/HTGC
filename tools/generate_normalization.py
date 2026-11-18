#!/usr/bin/env python3
"""Generate the Unicode normalization tables from Unicode 17.0.0 UCD files."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('ucd', type=Path)
args = parser.parse_args()
properties = (args.ucd / 'DerivedNormalizationProps.txt').read_text()
if not properties.startswith('# DerivedNormalizationProps-17.0.0.txt'):
    parser.error('Expected Unicode 17.0.0 DerivedNormalizationProps.txt')
exclusions = set()
for line in properties.splitlines():
    fields = line.split('#', 1)[0].strip().split(';')
    if len(fields) < 2 or fields[1].strip() != 'Full_Composition_Exclusion':
        continue
    start, *end = fields[0].strip().split('..')
    exclusions.update(range(int(start, 16), int(end[0], 16) + 1 if end else int(start, 16) + 1))
classes, decompositions, compositions = [], [], []
for line in (args.ucd / 'UnicodeData.txt').read_text().splitlines():
    fields = line.split(';')
    cp, ccc, mapping = int(fields[0], 16), int(fields[3]), fields[5]
    if ccc:
        classes.append(f'{cp:x}:{ccc:x}')
    if mapping:
        parts = mapping.split()
        compatibility = parts[0].startswith('<')
        if compatibility:
            parts = parts[1:]
        decompositions.append(f'{cp:x}:{"k" if compatibility else "c"}{".".join(part.lower() for part in parts)}')
        if not compatibility and len(parts) == 2 and cp not in exclusions:
            compositions.append(f'{int(parts[0],16):x}.{int(parts[1],16):x}:{cp:x}')

def dart_string(name, values):
    lines, current = [], ''
    for value in values:
        entry = value + ','
        if len(current) + len(entry) > 100:
            lines.append(current)
            current = ''
        current += entry
    if current:
        lines.append(current)
    return f'const {name} =\n' + '\n'.join("    '" + line + "'" for line in lines) + ';\n'

output = """part of 'js_core.dart';

// Generated from Unicode 17.0.0 UnicodeData.txt and DerivedNormalizationProps.txt.
// Unicode data copyright and permission notice: runtime/UNICODE-LICENSE.txt.
"""
license_text = Path('runtime/UNICODE-LICENSE.txt').read_text()
output += '//\n' + ''.join(('// ' + line if line else '//') + '\n' for line in license_text.splitlines()) + '\n'
output += dart_string('_jUnicodeCombiningData', classes)
output += dart_string('_jUnicodeDecompositionData', decompositions)
output += dart_string('_jUnicodeCompositionData', compositions)
Path('runtime/js_unicode_data.dart').write_text(output)
