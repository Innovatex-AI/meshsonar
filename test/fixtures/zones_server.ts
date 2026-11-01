// Test fixture: runs the website's REAL privacy-zone code (meshcore-insights src/lib/platform/zone-handlers.ts and
// zones.ts, the ONE validator) over a small in-memory store, so test/core/privacy_zones_contract_test.dart can check the
// app against the server's own rules.
//
//   bun run test/fixtures/zones_server.ts <driverKey> [cmatDir]
// Prints "PORT <n>" once listening. Routes: GET|POST /api/cmh/driver-privacy (x-driver-key), POST /__validate
// (body = one zone as JSON -> validateZone's answer), GET /__test/state (what the store holds).
const driverKey = process.argv[2] ?? "contract-driver-key-0123456789";
const cmatDir = process.argv[3] ?? "/home/claude/meshcore-insights";
const { makeZoneHandlers } = await import(`${cmatDir}/src/lib/platform/zone-handlers.ts`);
const { validateZone } = await import(`${cmatDir}/src/lib/platform/zones.ts`);
const { sha256Hex } = await import(`${cmatDir}/src/lib/drive/handlers.ts`);

const keySha = await sha256Hex(driverKey);
const row = { driverId: "d1", userId: null as string | null, trimM: 500, privacyZones: [] as unknown[] };
const store = {
  async driverByKey(sha: string) { return sha === keySha ? { ...row } : null; },
  async setDriverPrivacy(_id: string, p: { trimM?: number; privacyZones?: unknown[] }) { if (p.trimM !== undefined) row.trimM = p.trimM; if (p.privacyZones) row.privacyZones = p.privacyZones; },
  async setUserPrivacy(_id: string, p: { trimM?: number; privacyZones?: unknown[] }) { if (p.trimM !== undefined) row.trimM = p.trimM; if (p.privacyZones) row.privacyZones = p.privacyZones; },
};
const handlers = makeZoneHandlers({ store, principal: async () => ({ kind: "anonymous" }), rateLimit: async () => null }) as Record<string, (req: Request) => Promise<Response>>;

const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/__test/state") return Response.json(row);
    if (url.pathname === "/__validate" && req.method === "POST") return Response.json(validateZone(await req.json(), 0));
    const m = url.pathname.match(/^\/api\/cmh\/([a-z-]+)$/);
    const h = m ? handlers[m[1]] : undefined;
    if (!h) return Response.json({ error: "not found" }, { status: 404 });
    try { return await h(req); } catch (e) { return Response.json({ error: String(e) }, { status: 500 }); }
  },
});
console.log(`PORT ${server.port}`);
