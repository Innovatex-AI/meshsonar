// Test fixture for AC-10 (spec m1-app-0.4.0 §8): runs CMAT's REAL problem-report handler
// (meshcore-insights src/lib/platform/report-handlers.ts, branch m1/problem-reports) with its in-memory store, so the Dart
// contract test (test/core/cmat_report_contract_test.dart) talks to the actual server code. Skipped when absent.
//
//   bun run test/fixtures/cmat_report_server.ts <cmatDir> <approvedDriverKey>
// Prints "PORT <n>" once listening. Routes: POST /api/cmh/problem-report, GET /__test/reports -> {reports: [...]}.
//
// Uses the interface CMAT's own report-handlers.test.ts assumes (Q, 2026-10-17):
//   makeReportHandlers({ store, auth, now }) -> { "problem-report": (req) => Promise<Response>, ... }
//   memoryReportStore({ now?, config?, drivers?, users? }) with `_reports`; config { problem_reports: "on" };
//   drivers [{ id, keySha256, status, display, userId }]; auth { principal, requireRole, actorLabel, audit, rateLimit }.
// If CMAT's builder lands different names, align them here; the Dart side does not change.
const cmatDir = process.argv[2] ?? "/home/claude/meshcore-insights";
const driverKey = process.argv[3] ?? "ms_contractReportKey_0123456789abcdefghijklmn";
const reports = await import(`${cmatDir}/src/lib/platform/report-handlers.ts`);
const authCore = await import(`${cmatDir}/src/lib/platform/auth-core.ts`);
const { sha256Hex } = await import(`${cmatDir}/src/lib/drive/handlers.ts`);

const now = () => new Date();
const store = reports.memoryReportStore({
  now,
  config: { problem_reports: "on" },
  drivers: [{ id: "d-contract", keySha256: await sha256Hex(driverKey), status: "approved", display: "KE4BFI", userId: null }],
  users: [],
});
const auth = {
  principal: async () => ({ kind: "anon" }),
  requireRole: authCore.requireRole,
  actorLabel: authCore.actorLabel,
  audit: async () => {},
  rateLimit: async () => null,
};
const handlers = reports.makeReportHandlers({ store, auth, now }) as Record<string, (req: Request) => Promise<Response>>;

const server = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/__test/reports") {
      return Response.json({ reports: store._reports ?? [] });
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
