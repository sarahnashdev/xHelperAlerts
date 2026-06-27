/**
 * xHelperAlerts download proxy Worker
 *
 * Dynamically resolves the latest DMG from GitHub's API and 302s to
 * it. No hard-coded versions — every new release "just works" the
 * moment its release is published.
 *
 * Logs every download with country / city / colo / referrer / UA to
 * Cloudflare's Workers logs.
 */
export default {
  async fetch(request, env, ctx) {
    const cf = request.cf || {};

    console.log(JSON.stringify({
      event: 'download',
      country: cf.country,
      region: cf.region,
      city: cf.city,
      colo: cf.colo,
      asn: cf.asn,
      asOrganization: cf.asOrganization,
      referrer: request.headers.get('referer') || '',
      userAgent: request.headers.get('user-agent') || '',
      timestamp: new Date().toISOString(),
    }));

    // Look up the latest release on GitHub and grab the DMG asset.
    // Cached for 60 s at the edge so we don't hammer the API.
    const apiResp = await fetch(
      'https://api.github.com/repos/sarahnashdev/xHelperAlerts/releases/latest',
      {
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'xHelperAlerts-download-worker',
        },
        cf: { cacheTtl: 60, cacheEverything: true },
      }
    );

    let target = 'https://github.com/sarahnashdev/xHelperAlerts/releases/latest';
    if (apiResp.ok) {
      const release = await apiResp.json();
      const dmg = (release.assets || []).find(
        (a) => typeof a.name === 'string' && a.name.toLowerCase().endsWith('.dmg')
      );
      if (dmg && dmg.browser_download_url) {
        target = dmg.browser_download_url;
      }
    }

    return Response.redirect(target, 302);
  },
};
