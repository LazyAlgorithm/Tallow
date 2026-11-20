// Cross-origin isolation for a web game's page, where the host cannot set response headers (GitHub Pages, itch.io,
// a plain web server folder). A build with threads uses shared memory, which the browser allows only on a
// cross-origin isolated page; this service worker answers each same-origin request with the headers that isolation
// asks for (a page's threads also read their scripts through the worker, so the page's own answer alone is not
// enough). index.html registers it and reloads once when it takes over.
//
// After gzuidhof/coi-serviceworker (MIT), narrowed to a game's same-origin files.
"use strict";

if (typeof window === "undefined") {
	self.addEventListener("install", () => self.skipWaiting());
	self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

	self.addEventListener("fetch", (event) => {
		const request = event.request;
		// A cache-only request for another origin cannot be re-fetched through the worker; let the browser answer it.
		if (request.cache === "only-if-cached" && request.mode !== "same-origin")
			return;
		event.respondWith((async () => {
			try {
				const response = await fetch(request);
				// Opaque answers (a cross-origin file without CORS) cannot be given headers; hand them back as they are.
				if (response.type === "opaque" || response.status === 0)
					return response;
				const headers = new Headers(response.headers);
				headers.set("Cross-Origin-Embedder-Policy", "require-corp");
				headers.set("Cross-Origin-Opener-Policy", "same-origin");
				// The body is streamed through, so a large asset pack is not held in memory a second time.
				return new Response(response.body, {
					status: response.status,
					statusText: response.statusText,
					headers,
				});
			} catch (error) {
				return Response.error();
			}
		})());
	});
}
