"""Real Chromium geometry checks against production lists, virtual rows and P2.
Build with the adjacent webpack.config.js, then run with Python Playwright.
The transport and fixed-height status bodies are fixtures, not a Rails E2E.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[3]
BUNDLE = ROOT / 'tmp/filter-reconciliation-browser/fixture.js'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/fixture.js':
            body = BUNDLE.read_bytes()
            content_type = 'application/javascript'
        else:
            layout = 'document' if 'layout=document' in self.path else 'split' if 'layout=split' in self.path else 'columns'
            height = 'auto' if layout == 'document' else '340px' if layout == 'split' else '600px'
            overflow = 'visible' if layout == 'document' else 'auto'
            state = json.dumps({'meta': {'me': 'me', 'locale': 'en', 'max_frequently_used_emojis': 16}})
            body = f'''<!doctype html><meta charset="utf-8"><style>
body {{ margin: 0; overflow-anchor: none; }} .scrollable {{ height: {height}; overflow-y: {overflow}; overflow-anchor: none; }}
article {{ padding: 0; margin: 0; }} section {{ border: 1px solid black; }}
#composer {{ position: fixed; right: 0; bottom: 0; width: 220px; height: 45px; }}
</style><script id="initial-state" type="application/json">{state}</script>
<div id="root"></div><script src="/fixture.js"></script>'''.encode()
            content_type = 'text/html'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


ANCHOR = '''(pane) => {
 const node = document.querySelector(`#pane-${pane} .scrollable`);
 const isDoc = window.fixture.layout().documentScroll;
 const scroller = isDoc ? document.scrollingElement : node;
 const top = isDoc ? 0 : node.getBoundingClientRect().top;
 const row = [...node.querySelectorAll('article[data-id]')].find(row => {
   const r = row.getBoundingClientRect(); return r.height > 0 && r.bottom > top;
 });
 return {id: row?.dataset.id, offset: row ? row.getBoundingClientRect().top - top : null, scrollTop: scroller.scrollTop};
}'''


def run():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    Thread(target=server.serve_forever, daemon=True).start()
    results = []
    without_anchors = "--without-anchors" in sys.argv
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path='/usr/bin/chromium', headless=True, args=['--no-sandbox', '--disable-dev-shm-usage', '--enable-precise-memory-info'])
        for layout in ['document', 'columns', 'split']:
            for mix in [False, True]:
                page = browser.new_page(viewport={'width': 1100, 'height': 850})
                errors = []
                page.on('pageerror', lambda error: errors.append(str(error)))
                page.goto(f'http://127.0.0.1:{server.server_port}/?layout={layout}&mix={int(mix)}&anchors={"off" if without_anchors else "on"}')
                page.wait_for_function('!!window.fixture', timeout=30000)
                page.wait_for_timeout(250)
                page.evaluate('''() => {
                  const doc = window.fixture.layout().documentScroll;
                  [...document.querySelectorAll('.scrollable')].forEach((node, i) => {
                    (doc ? document.scrollingElement : node).scrollTop = 4000 + i * 320;
                    (doc ? document : node).dispatchEvent(new Event('scroll'));
                  });
                  window.savedComposer = document.querySelector('#composer');
                  window.savedState = window.fixture.store.getState();
                }''')
                page.wait_for_timeout(400)
                before = page.evaluate(ANCHOR, 0)
                ids = [str(int(before['id']) + i) for i in [1, 2, 3]]
                other_before = page.evaluate(ANCHOR, 1) if layout != 'document' else None
                page.evaluate('(ids) => window.fixture.change(ids)', ids)
                page.wait_for_function("window.fixture.stats().active === 0 && window.fixturePosts.length >= 2")
                page.wait_for_timeout(250)
                offset = page.evaluate('''(id) => {
                  const n = document.querySelector('#pane-0 .scrollable');
                  const row = n.querySelector(`article[data-id="${id}"]`);
                  return row ? row.getBoundingClientRect().top - (window.fixture.layout().documentScroll ? 0 : n.getBoundingClientRect().top) : null;
                }''', before['id'])
                delta = abs(offset - before['offset'])
                assert without_anchors or delta <= 2, (layout, mix, 'hide above', before, offset)
                if other_before:
                    other_after = page.evaluate(ANCHOR, 1)
                    assert without_anchors or other_after['id'] == other_before['id'] and abs(other_after['offset'] - other_before['offset']) <= 2, (layout, mix, other_before, other_after)
                page.evaluate('window.fixture.change([])')
                page.wait_for_timeout(650)
                restored = page.evaluate(ANCHOR, 0)
                assert without_anchors or restored['id'] == before['id'] and abs(restored['offset'] - before['offset']) <= 2, (layout, mix, 'restore', before, restored)
                # Matching results are reused for display-only warn/hide changes.
                posts_before = page.evaluate('window.fixturePosts.length')
                page.evaluate("(ids) => window.fixture.change(ids, 'warn')", ids)
                page.wait_for_timeout(650)
                warn = page.evaluate(ANCHOR, 0)
                assert without_anchors or warn['id'] == before['id'] and abs(warn['offset'] - before['offset']) <= 2, (layout, mix, 'warn', warn)
                posts_warn = page.evaluate('window.fixturePosts.length')
                assert posts_warn == posts_before + 2
                page.evaluate("(ids) => window.fixture.change(ids, 'hide', true)", ids)
                page.wait_for_timeout(250)
                assert page.evaluate('window.fixturePosts.length') == posts_warn
                page.evaluate('window.fixture.change([])')
                page.wait_for_timeout(650)
                # An anchor row can itself disappear; an adjacent stable row
                # must retain its own previous offset, rather than jump to top.
                anchor = page.evaluate(ANCHOR, 0)
                page.evaluate('(id) => window.fixture.change([id])', anchor['id'])
                page.wait_for_timeout(650)
                gone = page.evaluate(ANCHOR, 0)
                assert gone['scrollTop'] > 1000, (layout, mix, 'anchor disappeared', gone)
                # User input between snapshot and rAF must cancel correction.
                manual = page.evaluate('''() => {
                  window.fixture.change([], 'hide', true);
                  const node = document.querySelector('#pane-0 .scrollable');
                  const target = window.fixture.layout().documentScroll ? document : node;
                  const scroller = window.fixture.layout().documentScroll ? document.scrollingElement : node;
                  target.dispatchEvent(new WheelEvent('wheel', {deltaY: 200}));
                  scroller.scrollTop += 200;
                  return scroller.scrollTop;
                }''')
                page.wait_for_timeout(200)
                manual_after = page.evaluate(ANCHOR, 0)['scrollTop']
                assert abs(manual - manual_after) <= 2, (layout, mix, 'manual', manual, manual_after)
                intact = page.evaluate('''() => {
                  const after = window.fixture.store.getState();
                  return document.querySelector('#composer') === window.savedComposer && window.savedComposer.value === 'portable draft retained' && ['compose','composers','statuses','timelines'].every(key => after.get(key) === window.savedState.get(key));
                }''')
                assert intact, (layout, mix, 'draft/state identity')
                stats = page.evaluate('window.fixture.stats()')
                posts = page.evaluate('window.fixturePosts')
                # Rebind a mounted list to the other scroll target, then filter
                # again. The existing first list and Composer must survive.
                next_layout = 'columns' if layout == 'document' else 'document'
                page.evaluate('(mode) => window.fixture.switchLayout(mode)', next_layout)
                page.wait_for_timeout(300)
                assert page.evaluate('window.fixture.stats().surfaces') == (2 if next_layout == 'columns' else 1)
                page.evaluate("() => { const n = document.querySelector('#pane-0 .scrollable'); (window.fixture.layout().documentScroll ? document.scrollingElement : n).scrollTop = 3500; }")
                page.wait_for_timeout(250)
                switched = page.evaluate(ANCHOR, 0)
                page.evaluate('(ids) => window.fixture.change(ids)', [str(int(switched['id']) + 1)])
                page.wait_for_timeout(650)
                switched_after = page.evaluate(ANCHOR, 0)
                assert without_anchors or switched_after['id'] == switched['id'] and abs(switched_after['offset'] - switched['offset']) <= 2, (layout, mix, 'layout change', switched, switched_after)
                page.evaluate('window.fixture.unmount()')
                cleanup = page.evaluate('window.fixture.stats()')
                assert cleanup['surfaces'] == 0 and cleanup['retained'] == 0 and cleanup['timers'] == 0, cleanup
                assert not errors, errors
                results.append({'layout': layout, 'mix': mix, 'hide_delta_px': delta, 'restore_delta_px': abs(restored['offset'] - before['offset']), 'manual_delta_px': abs(manual - manual_after), 'posts': len(posts), 'max_batch': max(len(post['ids']) for post in posts), 'stats': stats, 'cleanup': cleanup})
                page.close()
        browser.close()
    server.shutdown()
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    run()
