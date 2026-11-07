document.querySelectorAll("[data-message]").forEach(element => {
    element.textContent = browser.i18n.getMessage(element.dataset.message);
});
const automatic = document.getElementById("automatic");
browser.storage.local.get({ automatic: true }).then(settings => {
    automatic.checked = settings.automatic;
});
automatic.addEventListener("change", () => {
    browser.storage.local.set({ automatic: automatic.checked });
});
browser.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
    const destination = BetterYouTubeLinks.appURL(tab?.url);
    if (destination) {
        const open = document.getElementById("open");
        open.href = destination;
        open.hidden = false;
    } else {
        document.getElementById("unsupported").hidden = false;
    }
});
