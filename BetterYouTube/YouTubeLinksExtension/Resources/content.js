(() => {
    if (window.top !== window) return;
    let automatic = false;
    let previousURL;
    let banner;
    const message = key => browser.i18n.getMessage(key);

    function update() {
        // Returning from the app or dismissing Safari's confirmation must not open it again.
        if (document.visibilityState === "hidden" || previousURL === location.href) return;
        const pageURL = location.href;
        previousURL = pageURL;
        const destination = BetterYouTubeLinks.appURL(location.href);
        banner?.remove();
        banner = undefined;
        if (!destination) return;

        const showButton = () => {
            if (pageURL !== location.href || !document.body) return;
            banner = document.createElement("aside");
            const shadow = banner.attachShadow({ mode: "closed" });
            const style = document.createElement("style");
            style.textContent = `:host { all: initial; position: fixed; top: 0; left: 0; right: 0; z-index: 2147483647; }
                div { color-scheme: light dark; background: Canvas; color: CanvasText; padding: 12px; padding-top: max(12px, env(safe-area-inset-top)); display: flex; gap: 16px; justify-content: center; align-items: center; font: 15px system-ui; border-bottom: 1px solid GrayText; }
                a { color: LinkText; } button { font: inherit; }`;
            const row = document.createElement("div");
            const link = document.createElement("a");
            link.href = destination;
            link.textContent = message("open");
            const close = document.createElement("button");
            close.textContent = message("dismiss");
            close.addEventListener("click", () => banner?.remove());
            row.append(link, close);
            shadow.append(style, row);
            document.body.append(banner);
        };
        if (document.body) showButton();
        else document.addEventListener("DOMContentLoaded", showButton, { once: true });
        // Safari may ask for confirmation or require a user gesture; the link above remains
        // usable in either case. Leave YouTube loaded so cancelling keeps a working web page.
        if (automatic) location.href = destination;
    }

    browser.storage.local.get({ automatic: true }).then(settings => {
        automatic = settings.automatic;
        update();
    }).catch(() => update());
    browser.storage.onChanged.addListener((changes, area) => {
        if (area === "local" && changes.automatic) automatic = changes.automatic.newValue;
    });

    // Following an ordinary YouTube link keeps the original user gesture. Modified clicks,
    // downloads and new tabs retain Safari's normal behavior.
    document.addEventListener("click", event => {
        if (!automatic || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        const anchor = event.target.closest?.("a[href]");
        if (!anchor || anchor.hasAttribute("download") || (anchor.target && anchor.target !== "_self")) return;
        const destination = BetterYouTubeLinks.appURL(anchor.href);
        if (!destination) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        location.href = destination;
    }, true);

    // YouTube navigates without loading a new document. Observing the address also catches
    // history changes in both its desktop and mobile sites without inspecting page content.
    setInterval(update, 1000);
    document.addEventListener("visibilitychange", update);
})();
