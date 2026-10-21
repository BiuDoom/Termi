#!/usr/bin/env python3
"""add-strings.py <Localizable.xcstrings> <strings.json> — add zh-Hans translations to the string catalog
WITHOUT re-serializing it (entries are inserted as text, in sorted position, in Xcode's own formatting).

strings.json: [{"key": "Last Connected", "zh": "上次连接"},
               {"key": "%lld sessions", "zh": "%lld 个会话", "enOne": "%lld session", "enOther": "%lld sessions"}]
Use enOne / enOther for every key that counts something (English needs a singular). Keys already in the
catalog are left alone (reported); a different existing translation is reported as a CONFLICT and left
alone too — pick another English key, or change that entry's "value" line by hand.

The key is the English text exactly as the code writes it, with interpolations as format specifiers
("\\(name)" of a String is %@, of an Int is %lld). Check the result with "make check-strings".
A build from the Xcode IDE may move a new entry to the position Xcode's own ordering gives it."""
import json, re, sys

def q(s):
    return json.dumps(s, ensure_ascii=False).replace('/', '\\/')

def unit(indent, value):
    p = ' ' * indent
    return [p + '"stringUnit" : {', p + '  "state" : "translated",', p + '  "value" : ' + q(value), p + '}']

def entry(item):
    lines = ['    ' + q(item['key']) + ' : {', '      "localizations" : {']
    if item.get('enOne') and item.get('enOther'):
        lines += ['        "en" : {', '          "variations" : {', '            "plural" : {', '              "one" : {']
        lines += unit(16, item['enOne']) + ['              },', '              "other" : {']
        lines += unit(16, item['enOther']) + ['              }', '            }', '          }', '        },']
    lines += ['        "zh-Hans" : {'] + unit(10, item['zh']) + ['        }', '      }', '    },']
    return lines

def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    path, items = sys.argv[1], json.load(open(sys.argv[2], encoding='utf-8'))
    added = 0
    for item in items:
        key, zh = item['key'], item['zh']
        text = open(path, encoding='utf-8').read()
        catalog = json.loads(text)['strings']
        if key in catalog:
            old = catalog[key].get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value')
            print(('exists   ' if old == zh else 'CONFLICT ') + repr(key) + ((' has ' + repr(old) + ', wanted ' + repr(zh)) if old != zh else ''))
            continue
        lines = text.split('\n')
        tops = []
        for i, line in enumerate(lines):
            m = re.match(r'^    ("(?:[^"\\]|\\.)*") : \{$', line)
            if m:
                tops.append((i, json.loads(m.group(1))))
        after = [i for i, k in tops if k.lower() > key.lower()]
        at = after[0] if after else tops[-1][0]
        lines[at:at] = entry(item)
        new = '\n'.join(lines)
        check = json.loads(new)['strings']
        assert len(check) == len(catalog) + 1 and check[key]['localizations']['zh-Hans']['stringUnit']['value'] == zh
        open(path, 'w', encoding='utf-8').write(new)
        added += 1
        print('added    ' + repr(key))
    print('%d added, catalog has %d keys' % (added, len(json.load(open(path, encoding='utf-8'))['strings'])))
    return 0

sys.exit(main())
