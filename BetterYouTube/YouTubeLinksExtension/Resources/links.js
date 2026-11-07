// Keep accepted destinations in step with YouTubeLink.swift. Pass the original URL through
// untouched so timestamps and any future parameters reach the app's authoritative parser.
globalThis.BetterYouTubeLinks = {
    appURL(value) {
        let url;
        try { url = new URL(value); } catch { return null; }
        if (!["http:", "https:"].includes(url.protocol)) return null;
        const host = url.hostname.toLowerCase();
        if (!["youtube.com", "youtu.be"].some(domain => host === domain || host.endsWith("." + domain))) return null;
        const parts = url.pathname.split("/").filter(Boolean);
        const video = value => /^[A-Za-z0-9_-]{11}$/.test(value ?? "");
        let supported = false;
        if (host === "youtu.be" || host === "www.youtu.be") {
            supported = video(parts[0]);
        } else {
            switch ((parts[0] ?? "").toLowerCase()) {
            case "watch": supported = video(url.searchParams.get("v")); break;
            case "shorts": case "live": case "v": case "e":
                supported = video(parts[1]); break;
            case "playlist": supported = /^[A-Za-z0-9_-]{2,64}$/.test(url.searchParams.get("list") ?? ""); break;
            case "channel": supported = /^UC[A-Za-z0-9_-]{22}$/.test(parts[1] ?? ""); break;
            default: supported = /^@[A-Za-z0-9._-]{3,30}$/.test(parts[0] ?? "");
            }
        }
        return supported ? "betteryoutube://open?url=" + encodeURIComponent(url.href) : null;
    }
};
