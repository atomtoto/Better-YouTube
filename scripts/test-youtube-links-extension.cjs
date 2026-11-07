const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.join(__dirname, '../BetterYouTube/YouTubeLinksExtension/Resources');
const links = readFileSync(path.join(root, 'links.js'), 'utf8');
const content = readFileSync(path.join(root, 'content.js'), 'utf8');
const context = vm.createContext({ URL });
vm.runInContext(links, context);
const appURL = context.BetterYouTubeLinks.appURL;

const video = 'dQw4w9WgXcQ';
test('YouTube destinations preserve the complete URL, including timestamps', () => {
    for (const url of [
        `https://www.youtube.com/watch?v=${video}&t=1m30s&list=PL123`,
        `https://m.youtube.com/watch?v=${video}#t=42`,
        `https://music.youtube.com/watch?v=${video}`,
        `https://youtu.be/${video}?t=90`,
        `https://www.youtu.be/${video}`,
        `http://youtube.com/shorts/${video}`,
        `https://youtube.com/live/${video}`,
        'https://youtube.com/playlist?list=PL123',
        'https://youtube.com/channel/UCBR8-60-B28hp2BmDPdntcQ',
        'https://youtube.com/@YouTube/videos'
    ]) {
        const wrapped = new URL(appURL(url));
        assert.equal(wrapped.protocol, 'betteryoutube:');
        assert.equal(wrapped.searchParams.get('url'), url);
    }
});

test('unrelated domains, unsupported pages, embeds and invalid IDs stay in Safari', () => {
    for (const url of [
        undefined, '', 'not a URL',
        `https://youtube.com.attacker.example/watch?v=${video}`,
        `https://youtube.com@attacker.example/watch?v=${video}`,
        `https://notyoutube.com/watch?v=${video}`,
        `betteryoutube://watch?v=${video}`,
        `ftp://youtube.com/watch?v=${video}`,
        'https://accounts.google.com/', 'https://youtube.com/',
        'https://youtube.com/feed/subscriptions', 'https://youtube.com/watch?v=invalid',
        'https://youtube.com/playlist?list=', 'https://youtube.com/channel/invalid',
        `https://youtube.com/embed/${video}`, 'https://youtube.com/@a'
    ]) assert.equal(appURL(url), null, String(url));
});

async function page({ automatic = true, url = `https://youtube.com/watch?v=${video}`, framed = false, visible = true } = {}) {
    const listeners = {};
    const redirects = [];
    const banners = [];
    let current = url;
    let tick, change;
    const element = () => ({
        append() {}, attachShadow: () => ({ append() {} }), addEventListener() {},
        remove() { this.removed = true; }
    });
    const document = {
        visibilityState: visible ? 'visible' : 'hidden',
        body: { append: banner => banners.push(banner) },
        createElement: element,
        addEventListener: (name, callback) => { listeners[name] = callback; }
    };
    const location = {
        get href() { return current; },
        set href(value) { redirects.push(value); } // Opening an app leaves the web page in place.
    };
    const window = {};
    window.top = framed ? {} : window;
    const sandbox = vm.createContext({
        URL, document, location, window,
        browser: {
            i18n: { getMessage: key => key },
            storage: {
                local: { get: async () => ({ automatic }) },
                onChanged: { addListener: callback => { change = callback; } }
            }
        },
        setInterval: callback => { tick = callback; }
    });
    vm.runInContext(links, sandbox);
    vm.runInContext(content, sandbox);
    await new Promise(resolve => setImmediate(resolve));
    return { listeners, redirects, banners, show: () => { document.visibilityState = 'visible'; listeners.visibilitychange?.(); }, tick: () => tick?.(), navigate: url => { current = url; tick?.(); }, change: value => change?.({ automatic: { newValue: value } }, 'local') };
}

test('redirects once, offers a fallback and does not loop on return from the app', async () => {
    const p = await page();
    assert.equal(p.redirects.length, 1);
    assert.equal(p.banners.length, 1);
    p.tick();
    p.listeners.visibilitychange();
    assert.equal(p.redirects.length, 1);
    p.navigate(`https://youtube.com/shorts/${video}?t=12`);
    assert.equal(p.redirects.length, 2);
    assert.equal(p.banners[0].removed, true);
    p.navigate('https://youtube.com/feed/subscriptions');
    assert.equal(p.redirects.length, 2);
    assert.equal(p.banners[1].removed, true);
});

test('automatic opening can be disabled and re-enabled without opening the current page again', async () => {
    const p = await page({ automatic: false });
    assert.equal(p.redirects.length, 0);
    assert.equal(p.banners.length, 1);
    p.change(true);
    p.tick();
    assert.equal(p.redirects.length, 0);
    p.navigate(`https://youtu.be/${video}?t=10`);
    assert.equal(p.redirects.length, 1);
});

test('embedded and background documents never trigger opening', async () => {
    const iframe = await page({ framed: true });
    assert.equal(iframe.redirects.length, 0);
    const hidden = await page({ visible: false });
    assert.equal(hidden.redirects.length, 0);
    hidden.show();
    assert.equal(hidden.redirects.length, 1);
    const p = await page({ url: 'https://youtube.com/' });
    p.navigate(`https://youtube.com/embed/${video}`);
    assert.equal(p.redirects.length, 0);
});

test('ordinary clicks route to the app, modified clicks and new tabs remain native', async () => {
    const p = await page({ url: 'https://youtube.com/' });
    function click(overrides = {}, anchorOverrides = {}) {
        let prevented = false;
        const anchor = { href: `https://youtu.be/${video}?t=55`, target: '', hasAttribute: () => false, ...anchorOverrides };
        p.listeners.click({
            button: 0, target: { closest: () => anchor },
            preventDefault: () => { prevented = true; }, stopImmediatePropagation() {}, ...overrides
        });
        return prevented;
    }
    assert.equal(click(), true);
    assert.equal(p.redirects.length, 1);
    for (const modifier of ['metaKey', 'ctrlKey', 'shiftKey', 'altKey', 'defaultPrevented']) {
        assert.equal(click({ [modifier]: true }), false);
    }
    assert.equal(click({ button: 1 }), false);
    assert.equal(click({}, { target: '_blank' }), false);
    assert.equal(click({}, { hasAttribute: () => true }), false);
    p.change(false);
    assert.equal(click(), false);
    assert.equal(p.redirects.length, 1);
});

test('manifest restricts injection to YouTube top-level pages and all translations exist', () => {
    const manifest = JSON.parse(readFileSync(path.join(root, 'manifest.json')));
    assert.deepEqual(manifest.permissions, ['storage', 'activeTab']);
    assert.equal(manifest.content_scripts[0].all_frames, false);
    for (const script of manifest.content_scripts[0].js) assert.ok(readFileSync(path.join(root, script)).length);
    const en = JSON.parse(readFileSync(path.join(root, '_locales/en/messages.json')));
    const fr = JSON.parse(readFileSync(path.join(root, '_locales/fr/messages.json')));
    assert.deepEqual(Object.keys(en).sort(), Object.keys(fr).sort());
    for (const value of Object.values(fr)) assert.ok(value.message.length);
});
