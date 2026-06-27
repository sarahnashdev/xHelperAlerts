/**
 * xHelperAlerts download proxy Worker
 *
 * Deploy this to Cloudflare Workers in the matthewknops account, then
 * bind it to threeluckystars.com/download/* via a route. Every request
 * gets logged with country / city / colo / referrer / UA, then
 * redirected to the latest GitHub Releases DMG.
 *
 * Logs show up in Cloudflare dashboard → Workers → this worker →
 * Real-Time Logs (or via `wrangler tail xhelperalerts-download`).
 *
 * For historical analytics, optionally bind a Workers Analytics Engine
 * dataset and uncomment the writeDataPoint call.
 */
export default {
  async fetch(request, env, ctx) {
    const cf = request.cf || {};
    const ua = request.headers.get('user-agent') || '';
    const referrer = request.headers.get('referer') || '';

    // Structured log — viewable in CF Workers Logs / Real-Time Logs.
    console.log(JSON.stringify({
      event: 'download',
      country: cf.country,
      region: cf.region,
      city: cf.city,
      colo: cf.colo,
      asn: cf.asn,
      asOrganization: cf.asOrganization,
      referrer,
      userAgent: ua,
      timestamp: new Date().toISOString(),
    }));

    // OPTIONAL: write to Workers Analytics Engine for queryable history.
    // To enable: in Cloudflare dashboard, add an Analytics Engine
    // binding to this worker named `DOWNLOADS_AE`, then uncomment.
    //
    // if (env.DOWNLOADS_AE) {
    //   env.DOWNLOADS_AE.writeDataPoint({
    //     blobs: [cf.country, cf.city, cf.colo, ua, referrer],
    //     indexes: [cf.country || 'unknown'],
    //   });
    // }

    // Redirect to GitHub Releases — `latest/download/<filename>` always
    // resolves to the most recent release, so this URL stays evergreen.
    const target = 'https://github.com/sarahnashdev/xHelperAlerts/releases/latest/download/xHelperAlerts-1.0.1.dmg';
    return Response.redirect(target, 302);
  },
};
