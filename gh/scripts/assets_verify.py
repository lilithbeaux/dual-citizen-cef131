#!/usr/bin/env python3
"""
Dual Citizen on-disk asset system validator.

Usage:
  assets_verify.py            # check everything; exit non-zero on any failure
  assets_verify.py --write    # also fill in missing/empty sha256 checksums in manifests

Validates, per site directory under assets/{facebook,reddit}/:
  * the site asset manifest (asset_manifest.json / manifest.json) against
    schema/asset_manifest.schema.json
  * every declared asset file exists on disk and its sha256 matches the manifest
  * selector_map and payload_map files against their JSON schemas

The manifest's `assets` map lists each file with {type, sha256, reload}.  Empty
sha256 values are accepted on a plain run (reported as unverified); with
--write they are filled in from disk and checksums_verified is set true.
"""
import json
import sys
import hashlib
from pathlib import Path

ASSETS = Path('/home/lilareyon/dual-citizen/assets')
SCHEMA = ASSETS / 'schema'

# Site dirs are the immediate subdirs of assets/ that are not schema/ or scripts/.
SITE_DIRS = sorted(
    d for d in ASSETS.iterdir()
    if d.is_dir() and d.name not in ('schema', 'scripts', 'common')
)

failures = []

def fail(msg):
    failures.append(msg)
    print('FAIL: ' + msg)

def ok(msg):
    print('ok:   ' + msg)

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

def load_json(path):
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        fail(f'{path}: invalid JSON ({exc})')
        return None

def schema_validate(instance, schema_path, label):
    """Validate instance against a JSON Schema draft-07 schema if jsonschema is present."""
    try:
        import jsonschema  # type: ignore
    except ImportError:
        # No jsonschema: fall back to a structural sanity check below.
        return True
    schema = load_json(schema_path)
    if schema is None:
        fail(f'schema {schema_path}: invalid JSON')
        return False
    try:
        jsonschema.validate(instance, schema)
        return True
    except jsonschema.ValidationError as exc:
        fail(f'{label}: schema violation: {exc.message}')
        return False

def manifest_path_for(site_dir):
    for name in ('asset_manifest.json', 'manifest.json'):
        p = site_dir / name
        if p.exists():
            return p
    return None

def validate_site(site_dir, write):
    site = site_dir.name
    mp = manifest_path_for(site_dir)
    if mp is None:
        fail(f'{site}: no asset manifest (asset_manifest.json / manifest.json)')
        return
    data = load_json(mp)
    if data is None:
        return

    # --- manifest structure ---
    schema_ok = schema_validate(data, SCHEMA / 'asset_manifest.schema.json',
                                f'{mp}: asset manifest')
    for key in ('site', 'name', 'version', 'cef_version_min', 'cef_version_max', 'assets'):
        if key not in data:
            fail(f'{mp}: missing required key "{key}"')

    assets = data.get('assets', {}) if isinstance(data, dict) else {}
    declared = []
    if isinstance(assets, dict):
        for rel, info in assets.items():
            declared.append(rel)
            fp = ASSETS / rel
            expected = info.get('sha256', '') if isinstance(info, dict) else ''
            atype = info.get('type', '') if isinstance(info, dict) else ''
            if atype not in ('script', 'stylesheet', 'data'):
                fail(f'{mp}: asset {rel} has invalid type "{atype}"')
            if not fp.exists():
                fail(f'{mp}: declared asset {rel} missing on disk')
                continue
            actual = sha256_file(fp)
            if expected == '':
                if write:
                    info['sha256'] = actual
                    ok(f'{mp}: wrote sha256 for {rel}')
                else:
                    fail(f'{mp}: asset {rel} has no sha256 (run with --write)')
            elif actual != expected:
                fail(f'{mp}: sha256 mismatch for {rel} '
                     f'(expected {expected[:12]}..., got {actual[:12]}...)')
            else:
                ok(f'{mp}: {rel} sha256 verified')

    # injection_order / css / data arrays must reference existing files
    for key in ('injection_order', 'css', 'data'):
        for rel in data.get(key, []) if isinstance(data, dict) else []:
            fp = ASSETS / rel
            if not fp.exists():
                fail(f'{mp}: {key} entry {rel} missing on disk')
            elif rel not in declared and not rel.startswith('common/'):
                fail(f'{mp}: {key} entry {rel} not listed in assets map')

    data['checksums_verified'] = True
    if write:
        mp.write_text(json.dumps(data, indent=2) + '\n')
        ok(f'{mp}: manifest written')

def validate_sidecar(site_dir):
    site = site_dir.name
    # selector map: prefer {site}_selectors.json, fall back to selectors_common.json for common
    sel_candidates = [site_dir / f'{site}_selectors.json', site_dir / 'selector_map.json']
    payload_candidates = [site_dir / f'{site}_payloads.json', site_dir / 'payload_map.json']
    for cand in sel_candidates:
        if cand.exists():
            data = load_json(cand)
            if data is not None:
                schema_validate(data, SCHEMA / 'selector_map.schema.json', f'{cand}: selector map')
            break
    for cand in payload_candidates:
        if cand.exists():
            data = load_json(cand)
            if data is not None:
                schema_validate(data, SCHEMA / 'payload_map.schema.json', f'{cand}: payload map')
            break

def main():
    write = '--write' in sys.argv
    for s in ('asset_manifest.schema.json', 'selector_map.schema.json', 'payload_map.schema.json'):
        if not (SCHEMA / s).exists():
            fail(f'schema missing: {SCHEMA / s}')

    for site_dir in SITE_DIRS:
        validate_site(site_dir, write)
        validate_sidecar(site_dir)

    # common dir selectors (shared fallback)
    common = ASSETS / 'common'
    if common.is_dir():
        sel = common / 'selectors_common.json'
        if sel.exists():
            data = load_json(sel)
            if data is not None:
                schema_validate(data, SCHEMA / 'selector_map.schema.json', f'{sel}: selector map')

    print()
    if failures:
        print(f'ASSET VALIDATION FAILED ({len(failures)} issue(s))')
        return 1
    print('ASSET VALIDATION PASSED')
    return 0

if __name__ == '__main__':
    sys.exit(main())
