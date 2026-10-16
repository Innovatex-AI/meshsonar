// Test fixture: runs CMAT's real MeshSonar endpoint handlers (meshcore-insights src/lib/drive/handlers.ts) with the
// in-memory store, so the Dart contract test (test/core/cmat_contract_test.dart) talks to the actual server code.
//
//   bun run test/fixtures/cmat_server.ts [adminKey]
// Prints "PORT <n>" once listening on a free port. Routes: /api/cmh/<driver-request|driver-status|drive-upload|
// drive-repeaters|driver-admin>, plus GET /__test/state -> {sessions: [{id, endedAt, pingCount}], pings: n}.
import { makeDriveHandlers, memoryDriveStore, sha256Hex } from "/home/claude/meshcore-insights/src/lib/drive/handlers.ts";

const adminKey = process.argv[2] ?? "test-admin-key-0123456789";
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
        pings: [...store._pings.values()].map((p) => ({ id: p.id, echoes: p.echoes.length, neighbor: p.neighbor !== null })),
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
