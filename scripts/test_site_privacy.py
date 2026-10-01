"""Render actual checked-out Yap HTML with public counters stubbed equally for both revisions."""
import argparse, functools, http.server, json, threading
from pathlib import Path
from playwright.sync_api import sync_playwright
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--before', required=True, type=Path)
    parser.add_argument('--after', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    # Serve only the two public website fixtures from separate loopback servers.
    OUT=args.output/'screenshots';OUT.mkdir(parents=True, exist_ok=True)
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self,*args): pass
    servers={}
    for phase, root in [('before', args.before), ('after', args.after)]:
     server=http.server.ThreadingHTTPServer(('127.0.0.1', 0),functools.partial(Handler,directory=str(root.resolve())))
     threading.Thread(target=server.serve_forever,daemon=True).start()
     servers[phase]=server
    results=[]
    try:
     with sync_playwright() as p:
      browser=p.chromium.launch(headless=True)
      for phase in ['before', 'after']:
       for lang in ['en','zh-Hans']:
        for viewport in [{'width':1440,'height':1000},{'width':390,'height':844}]:
         ctx=browser.new_context(viewport=viewport,locale=lang,color_scheme='light',reduced_motion='reduce')
         page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
         page.route('https://api.github.com/**',lambda route:route.fulfill(status=200,content_type='application/json',body='{}'))
         page.goto(f'http://127.0.0.1:{servers[phase].server_port}/index.html',wait_until='networkidle')
         if page.locator('html').get_attribute('data-lang') != lang:
          page.locator('#lang-toggle').click()
         assert page.locator('html').get_attribute('data-lang') == lang
         section=page.locator('#privacy');section.scroll_into_view_if_needed()
         label=f'{phase}-privacy-{lang}-{viewport["width"]}'
         section.screenshot(path=str(OUT/f'{label}.png'),animations='disabled')
         text=section.inner_text()
         if phase=='after':
          assert 'Yap collects no usage data' not in text
          assert ('Agent Access (MCP)' if lang=='en' else 'Agent 访问（MCP）') in text
          assert ('both transcription and enhancement' if lang=='en' else '转写和增强都使用本地模型') in text
         geometry=page.evaluate('({viewport:innerWidth,width:document.documentElement.scrollWidth})')
         assert geometry['width']<=geometry['viewport'],geometry
         assert not errors,errors
         # Exercise the actual language toggle twice, including after scrolling; copy must remain in selected language.
         page.locator('#lang-toggle').click();page.locator('#lang-toggle').click()
         assert page.locator('html').get_attribute('data-lang') == lang
         offline=page.locator('details').filter(has=page.get_by_text('Does it work offline?' if lang=='en' else '能离线用吗？',exact=True))
         offline.locator('summary').click();assert offline.get_attribute('open') is not None
         offline.screenshot(path=str(OUT/f'{phase}-offline-{lang}-{viewport["width"]}.png'))
         results.append({'phase':phase,'language':lang,'viewport':viewport,'source':str(args.before if phase == 'before' else args.after),'privacy_screenshot':f'{label}.png','horizontal_overflow':False,'javascript_errors':errors,'language_toggle_roundtrip':'pass','offline_faq_expansion':'pass'})
         ctx.close()
      browser.close()
    finally:
     for server in servers.values(): server.shutdown()
    (OUT.parent/'browser-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'cases':len(results),'screenshots':len(list(OUT.glob('*.png'))),'all_passed':True}))


if __name__ == "__main__":
    main()
