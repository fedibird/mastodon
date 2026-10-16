"""Frame-paced counter/import stress: DOM reads, CDP layouts and long tasks.
Fixed-height bodies render real counter text changes; this is not full-media E2E.
"""
import json
from http.server import ThreadingHTTPServer
from threading import Thread
from playwright.sync_api import sync_playwright
from run import Handler

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Thread(target=server.serve_forever, daemon=True).start()
with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', headless=True, args=['--no-sandbox', '--disable-dev-shm-usage'])
    for count in [1000, 2000]:
        page = browser.new_page(viewport={'width': 1100, 'height': 850})
        page.goto(f'http://127.0.0.1:{server.server_port}/?layout=columns&count={count}', timeout=120000)
        page.wait_for_function('!!window.fixture', timeout=120000)
        page.evaluate("document.querySelectorAll('.scrollable').forEach(node => {node.scrollTop = 4000; node.dispatchEvent(new Event('scroll'));})")
        page.wait_for_timeout(600)
        page.evaluate('window.fixture.prepareCounters()')
        cdp = page.context.new_cdp_session(page)
        cdp.send('Performance.enable')
        before = {item['name']: item['value'] for item in cdp.send('Performance.getMetrics')['metrics']}
        completed = []
        cdp.on('Tracing.tracingComplete', lambda event: completed.append(event))
        cdp.send('Tracing.start', {'categories': 'devtools.timeline,disabled-by-default-devtools.timeline.stack', 'transferMode': 'ReturnAsStream'})
        result = page.evaluate('window.fixture.counters()')
        after = {item['name']: item['value'] for item in cdp.send('Performance.getMetrics')['metrics']}
        cdp.send('Tracing.end')
        while not completed:
            page.wait_for_timeout(50)
        trace = ''
        while True:
            chunk = cdp.send('IO.read', {'handle': completed[0]['stream']})
            trace += chunk.get('data', '')
            if chunk.get('eof'):
                break
        cdp.send('IO.close', {'handle': completed[0]['stream']})
        events = json.loads(trace)['traceEvents']
        layouts = [event for event in events if event.get('name') == 'Layout' and event.get('ph') == 'X']
        synchronous = [event for event in layouts if event.get('args', {}).get('beginData', {}).get('stackTrace')]
        result.update({'traced_layouts': len(layouts), 'synchronous_layouts_with_js_stack': len(synchronous), 'synchronous_layout_ms': sum(event.get('dur', 0) for event in synchronous) / 1000})
        result.update({'count': count, 'columns': 2, 'layout_count': after['LayoutCount'] - before['LayoutCount'], 'layout_ms': (after['LayoutDuration'] - before['LayoutDuration']) * 1000, 'task_cpu_ms': (after['TaskDuration'] - before['TaskDuration']) * 1000})
        print(json.dumps(result), flush=True)
        page.evaluate('window.fixture.unmount()')
        page.close()
    browser.close()
server.shutdown()
