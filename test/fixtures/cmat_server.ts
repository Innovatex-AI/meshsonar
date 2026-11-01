// Test fixture: runs CMAT's real MeshSonar endpoint handlers (meshcore-insights src/lib/drive/handlers.ts) with the
// in-memory store, so the Dart contract tests (test/core/cmat_contract_test.dart, test/integration/end_to_end_test.dart)
// talk to the actual server code.
//
//   bun run test/fixtures/cmat_server.ts [adminKey] [cmatDir]
// cmatDir defaults to /home/claude/meshcore-insights (the Dart side passes CMAT_DIR, see test/core/cmat_env.dart).
// Prints "PORT <n>" once listening. Routes: /api/cmh/<driver-request|driver-status|drive-upload|
// drive-repeaters|driver-admin>, plus GET /__test/state -> {sessions: [{id, endedAt, pingCount}], pings: n}.
const adminKey = process.argv[2] ?? "test-admin-key-0123456789";
const cmatDir = process.argv[3] ?? "/home/claude/meshcore-insights";
const { makeDriveHandlers, memoryDriveStore, sha256Hex } = await import(`${cmatDir}/src/lib/drive/handlers.ts`);

const store = memoryDriveStore({
  adminKeySha256: await sha256Hex(adminKey),
  repeaters: async () => [{ key: "df0136aabbccddeeff00112233445566778899aabbccddeeff00112233445566", name: "Test Repeater", lat: 40.12, lon: -82.93 }],
});
const handlers = makeDriveHandlers({ store }) as Record<string, (req: Request) => Promise<Response>>;

const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/__test/state") {
      return Response.json({
        sessions: [...store._sessions.values()].map((x) => ({ id: x.s.id, endedAt: x.s.endedAt, pingCount: x.pingCount, label: x.s.label })),
        pings: [...store._pings.values()].map((p) => ({ id: p.id, echoes: p.echoes.length, neighbor: p.neighbor !== null, windowMs: p.window_ms ?? null, outcome: p.outcome ?? null })),
      });
    }
    const m = url.pathname.match(/^\/api\/cmh\/([a-z-]+)$/);
    const h = m ? handlers[m[1]] : undefined;
    if (!h) return Response.json({ error: "not found" }, { status: 404 });
    try {
      return await h(req);
    } catch (e) {
      return Response.json({ error: String(e) }, { status: 500 });
    }
  },
});
console.log(`PORT ${server.port}`);
