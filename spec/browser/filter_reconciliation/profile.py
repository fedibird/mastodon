"""CPU/heap/latency measurements for the deterministic browser fixture."""
import json
from http.server import ThreadingHTTPServer
from threading import Thread
from playwright.sync_api import sync_playwright
from run import Handler

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Thread(target=server.serve_forever, daemon=True).start()
results = []
with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', headless=True, args=['--no-sandbox', '--disable-dev-shm-usage', '--enable-precise-memory-info'])
    for count in [1000, 2000]:
        page = browser.new_page(viewport={'width': 1100, 'height': 850})
        page.goto(f'http://127.0.0.1:{server.server_port}/?layout=columns&count={count}', timeout=120000)
        page.wait_for_function('!!window.fixture', timeout=120000)
        page.wait_for_timeout(600)
        cdp = page.context.new_cdp_session(page)
        cdp.send('Performance.enable')
        cdp.send('HeapProfiler.collectGarbage')
        before = cdp.send('Runtime.getHeapUsage')['usedSize']
        metrics_before = {item['name']: item['value'] for item in cdp.send('Performance.getMetrics')['metrics']}
        start = page.evaluate('''() => {
          const start = performance.now(); window.fixture.change([]); return start;
        }''')
        page.wait_for_function(f'window.fixturePosts.length === {count // 100} && window.fixture.stats().active === 0 && window.fixture.stats().timers === 0', timeout=120000)
        end = page.evaluate('performance.now()')
        metrics_after = {item['name']: item['value'] for item in cdp.send('Performance.getMetrics')['metrics']}
        cdp.send('HeapProfiler.collectGarbage')
        after = cdp.send('Runtime.getHeapUsage')['usedSize']
        posts = page.evaluate('window.fixturePosts')
        stats = page.evaluate('window.fixture.stats()')
        page.evaluate('window.fixture.unmount()')
        page.wait_for_timeout(100)
        cdp.send('HeapProfiler.collectGarbage')
        released = cdp.send('Runtime.getHeapUsage')['usedSize']
        results.append({
            'count': count, 'columns': 2, 'posts': len(posts), 'max_batch': max(len(post['ids']) for post in posts),
            'first_post_ms': round(posts[0]['at'] - start, 2), 'completion_ms': round(end - start, 2),
            'min_post_interval_ms': round(min(b['at'] - a['at'] for a, b in zip(posts, posts[1:])), 2),
            'task_cpu_ms': round((metrics_after['TaskDuration'] - metrics_before['TaskDuration']) * 1000, 2),
            'heap_before_bytes': before, 'heap_after_bytes': after, 'heap_after_unmount_bytes': released,
            'stats': stats, 'cleanup': page.evaluate('window.fixture.stats()'),
        })
        assert len(posts) == count // 100 and stats['retained'] == count and stats['attempts'] == count
        print(json.dumps(results[-1]), flush=True)
        page.close()
    browser.close()
server.shutdown()

