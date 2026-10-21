#!/usr/bin/env python3
"""check-strings.py <Localizable.xcstrings> <build folder> <sources dir> [--prune] [--github]

Compares the string catalog with the keys the compiler saw in the sources. The app target is built
with SWIFT_EMIT_LOC_STRINGS=YES (project.yml), which writes one .stringsdata per source file into the
build's intermediates; <build folder> is any folder above them (DerivedData works): only the files of
the Termi target are read.

  missing      a key the code uses that has no zh-Hans translation      -> exit 1
  stale        a catalog entry no source file uses any more              -> listed; removed with --prune
  by variable  a catalog entry the compiler did not see, but whose text is a string literal somewhere
               in the sources (a title kept in an enum or a model and localized when shown)  -> kept

--github prints missing keys as GitHub error annotations and stale ones as warnings.
--prune removes the stale entries from the catalog as text (the file is never re-serialized, so the
diff shows only the removed entries). Keys that are built at run time (String(localized: variable),
LocalizedStringKey(variable)) are invisible to the compiler: list them in KEEP below with the reason.
"""
import json, re, sys, os

# Keys reached only through a variable. Each needs its reason.
KEEP = {
}


def used_keys(folder):
    keys = set()
    paths = []
    for root, _, files in os.walk(folder):
        # the app's own sources only: packages and the test bundle have string tables of their own
        if 'Termi.build' not in root.split(os.sep):
            continue
        paths += [os.path.join(root, name) for name in files if name.endswith('.stringsdata')]
    for path in paths:
        data = json.load(open(path, encoding='utf-8'))
        for table, entries in data.get('tables', {}).items():
            if table != 'Localizable':
                continue
            for entry in entries:
                keys.add(entry['key'])
    return keys


def literal_pattern(key):
    """The key as it would be written in Swift: %@ / %lld / %1$@ … are interpolations there."""
    parts = re.split(r'%(?:\d+\$)?(?:@|lld|ld|d|lf|f|\.\d+f)', key)
    body = r'\\\((?:[^()]|\([^()]*\))*\)'.join(re.escape(json.dumps(p, ensure_ascii=False)[1:-1]) for p in parts)
    return re.compile('"' + body + '"')


def source_text(folder):
    chunks = []
    for root, _, files in os.walk(folder):
        for name in files:
            if name.endswith('.swift'):
                chunks.append(open(os.path.join(root, name), encoding='utf-8').read())
    return '\n'.join(chunks)


def zh(entry):
    loc = entry.get('localizations', {}).get('zh-Hans', {})
    if 'stringUnit' in loc:
        return loc['stringUnit'].get('value')
    if 'variations' in loc:
        return 'variations'
    return None


def prune(path, stale):
    lines = open(path, encoding='utf-8').read().split('\n')
    out, i, removed = [], 0, 0
    while i < len(lines):
        m = re.match(r'^    ("(?:[^"\\]|\\.)*") : \{$', lines[i])
        if m and json.loads(m.group(1)) in stale:
            j = i + 1
            while not re.match(r'^    \},?$', lines[j]):
                j += 1
            i = j + 1
            removed += 1
            continue
        out.append(lines[i])
        i += 1
    text = '\n'.join(out)
    # the entry before the closing brace of "strings" must not end with a comma
    text = re.sub(r'\n    \},\n  \},', '\n    }\n  },', text)
    check = json.loads(text)['strings']
    assert removed == len(stale) and not (set(check) & stale), 'prune did not remove exactly the stale entries'
    open(path, 'w', encoding='utf-8').write(text)
    return removed


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    catalog_path, data_dir, sources_dir = args[0], args[1], args[2]
    catalog = json.load(open(catalog_path, encoding='utf-8'))['strings']
    used = used_keys(data_dir)
    if not used:
        print('no .stringsdata found in', data_dir)
        return 2
    missing = sorted(k for k in used if k and (k not in catalog or not zh(catalog[k])))
    unseen = sorted(k for k in catalog if k not in used and k not in KEEP)
    text = source_text(sources_dir)
    by_variable = [k for k in unseen if literal_pattern(k).search(text)]
    stale = [k for k in unseen if k not in set(by_variable)]
    print('%d keys in the catalog, %d seen by the compiler, %d more reached through a variable' % (len(catalog), len(used), len(by_variable)))
    print('missing zh-Hans: %d' % len(missing))
    for k in missing:
        print('  MISSING ' + json.dumps(k, ensure_ascii=False))
    print('stale: %d' % len(stale))
    for k in stale:
        print('  STALE   ' + json.dumps(k, ensure_ascii=False) + '  =  ' + json.dumps(zh(catalog[k]), ensure_ascii=False))
    if '--github' in sys.argv:
        for k in missing:
            print('::error file=Termi/Localizable.xcstrings::No zh-Hans translation for ' + json.dumps(k, ensure_ascii=False))
        for k in stale:
            print('::warning file=Termi/Localizable.xcstrings::Catalog entry no source uses: ' + json.dumps(k, ensure_ascii=False))
    if '--prune' in sys.argv and stale:
        print('removed %d stale entries' % prune(catalog_path, set(stale)))
    return 1 if missing else 0


sys.exit(main())
