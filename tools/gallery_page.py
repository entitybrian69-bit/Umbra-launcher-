#!/usr/bin/env python3
"""Build the gallery page: one HTML file the owner can open on a phone.

Why a generator and not a hand-written page: the pictures are per-run and named
for the build that took them, so the page has to be rebuilt from whatever is in
`evidence/ci/gallery/` and whatever is in `docs/gallery/`. A hand-written page
goes stale the first time a run adds a pose, which is exactly the failure the
gallery's own README has to guard against.

The output is a single file with `img` tags and no scripts, no fonts, no CDN:
it has to open from a phone on a slow connection, and it has to be readable in
the repository if Pages is ever off.

usage: tools/gallery_page.py [--out docs/index.html] [--dir evidence/ci/gallery]
"""
import argparse
import html
import os
import re
import subprocess
import sys

# `gallery-<pose>-<version>-<build>.png`, from the harness's own naming.
NAME = re.compile(r'^gallery-([a-z]+)-([0-9][0-9.]*)-([0-9a-f]{6,12})\.png$')

# The harness's own output directory, and the default for `--dir`.
DEFAULT_DIR = 'evidence/ci/gallery'

CAPTIONS = {
    'hills': 'grassy hills, from the highest ground in the save',
    'forest': 'under the trees, looking along the trunks',
    'shore': 'the waterline, close enough to see the blocks',
    'cave': 'below the surface, in the dark',
    'sky': 'upward, so the frame is mostly sky -- the test that a pose cannot cheat',
    'edge': 'the save\'s own edge, where the world stops',
}


def shots(directory, prefix):
    """(version, build, pose, url, bytes) for every shot in `directory`."""
    out = []
    if not os.path.isdir(directory):
        return out
    for name in sorted(os.listdir(directory)):
        m = NAME.match(name)
        if not m:
            continue
        pose, version, build = m.groups()
        path = os.path.join(directory, name)
        out.append({
            'v': tuple(int(p) for p in version.split('.')),
            'version': version,
            'build': build,
            'pose': pose,
            'url': prefix + name,
            'bytes': os.path.getsize(path),
        })
    return out


def describe(directory):
    """`git log -1 --format=%s` for the evidence commit, for the page's footer."""
    try:
        return subprocess.run(['git', 'log', '-1', '--format=%h %ci', '--', directory],
                              capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return ''


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='docs/index.html')
    ap.add_argument('--dir', default='evidence/ci/gallery')
    args = ap.parse_args(argv)

    # The committed copies live beside the page so a phone can fetch them without
    # reaching into `evidence/`, which is a directory of run output.
    # The committed copies are the default because that is what a static host serves.
    # `--dir` is honoured strictly: a fallback turned "this directory has no pictures"
    # into "here are the ones from somewhere else", which is the same class of mistake
    # as a gallery gate that passes a blank frame.
    if args.dir == DEFAULT_DIR:
        found = shots('docs/gallery', 'gallery/') or shots(args.dir, '')
    else:
        found = shots(args.dir, 'gallery/' if args.dir == 'docs/gallery' else '')
    if not found:
        print('gallery_page: no gallery PNGs in %s or docs/gallery' % args.dir,
              file=sys.stderr)
        return 1

    # Newest version first, and within a version the run's own build.
    found.sort(key=lambda s: (s['v'], s['pose']), reverse=True)
    newest = found[0]['version']
    mine = [s for s in found if s['version'] == newest]
    builds = sorted({s['build'] for s in mine})

    rows = []
    for s in mine:
        caption = CAPTIONS.get(s['pose'], s['pose'])
        rows.append(
            '<figure>\n'
            '  <a href="%s"><img src="%s" alt="%s: %s" loading="lazy"></a>\n'
            '  <figcaption><b>%s</b> &mdash; %s<br><small>%s &middot; %s KB</small>'
            '</figcaption>\n'
            '</figure>' % (
                html.escape(s['url']), html.escape(s['url']),
                html.escape(s['pose']), html.escape(caption),
                html.escape(s['pose']), html.escape(caption),
                html.escape(s['build']), s['bytes'] // 1024))

    page = """<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Umbra gallery %(version)s</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 16px; background: #14161c; color: #e8ecf4;
         font: 16px/1.45 system-ui, -apple-system, Segoe UI, Roboto, sans-serif; }
  h1 { font-size: 1.35rem; margin: 0 0 4px; }
  p.lead { margin: 0 0 20px; color: #9aa6bb; }
  figure { margin: 0 0 20px; }
  img { width: 100%%; height: auto; display: block; border-radius: 6px;
        background: #22252e; }
  figcaption { margin-top: 6px; font-size: .92rem; color: #c3cbdb; }
  small { color: #7f8b9f; }
  footer { margin-top: 28px; padding-top: 14px; border-top: 1px solid #2a2f3a;
           font-size: .85rem; color: #7f8b9f; }
  a { color: #8fc2ff; }
</style>
<h1>Umbra %(version)s &mdash; the gallery</h1>
<p class="lead">%(countword)s fixed pose%(plural)s in a real save, overlay off, taken on the CI
emulator by the app itself. Tap a picture for the full-size PNG.</p>
%(rows)s
<footer>
  <p>Build %(builds)s. These are the first gallery pictures this project has produced
  that are not a single flat colour: every earlier attempt was a frame fogged to the
  clear colour by a renderer that subtracted the camera twice.</p>
  <p>Emulator, not a phone: SwiftShader on x86_64. Frame times from this machine say
  nothing about a phone GPU, which is why the budget is reported here as a warning
  and gated on deterministic counts instead. Poses chosen by
  <code>tools/gallery_poses.py</code>; page generated by
  <code>tools/gallery_page.py</code>.</p>
  <p><a href="https://github.com/entitybrian69-bit/Umbra-launcher-">The repository</a></p>
</footer>
</html>
""" % {
        'version': html.escape(newest),
        'rows': '\n'.join(rows),
        'builds': html.escape(', '.join(builds)),
        # The count is the page's own, not a claim: a page that says "six" over one
        # picture is the same class of mistake as a gallery gate that passes a blank
        # frame, and the harness's own README already had to guard against it.
        'countword': {1: 'One', 2: 'Two', 3: 'Three', 4: 'Four', 5: 'Five',
                      6: 'Six'}.get(len(mine), str(len(mine))),
        'plural': '' if len(mine) == 1 else 's',
    }

    os.makedirs(os.path.dirname(args.out) or '.', exist_ok=True)
    with open(args.out, 'w') as f:
        f.write(page)
    print('gallery_page: %d picture(s) for %s -> %s (%d bytes)'
          % (len(mine), newest, args.out, len(page)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
