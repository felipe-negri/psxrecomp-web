// The WasmFS fetch backend sizes a disc file from the Content-Length of a HEAD
// response, inside a worker. Some hosts (Next.js route handlers) drop that
// header on HEAD. Fill it in from X-Content-Length, or from the total in the
// Content-Range of a one-byte ranged GET, before the backend sees the response.
if (typeof fetch === 'function' && !globalThis.__psxFetchSizePatched) {
  globalThis.__psxFetchSizePatched = true;
  const realFetch = fetch.bind(globalThis);
  globalThis.fetch = async (input, init) => {
    const response = await realFetch(input, init);
    if (!init || String(init.method).toUpperCase() !== 'HEAD' || !response.ok) return response;
    if (response.headers.get('Content-Length')) return response;
    let size = response.headers.get('X-Content-Length');
    if (!size) {
      const probe = await realFetch(input, {headers: {Range: 'bytes=0-0'}});
      const m = /\/(\d+)\s*$/.exec(probe.headers.get('Content-Range') || '');
      if (m) size = m[1];
      try { await probe.body?.cancel(); } catch (e) {}
    }
    if (!size) return response;
    const headers = new Headers(response.headers);
    headers.set('Content-Length', size);
    headers.set('Accept-Ranges', 'bytes');
    return new Response(null, {status: 200, statusText: 'OK', headers});
  };
}
