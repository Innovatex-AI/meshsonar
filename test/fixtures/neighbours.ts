// Test fixture: the website's REAL neighbour ordering (meshcore-insights src/lib/region/neighbours.ts regionsNear, what
// `regions-index?near=<slug>` serves and the website maps draw), run once over a regions-index file, so
// test/core/region_neighbours_contract_test.dart can check the app's on-device ordering matches it.
//
//   bun run test/fixtures/neighbours.ts <cmatDir> <regions-index.json> <slug> [limit]
// Prints a JSON array of slugs: the region itself, then its neighbours, nearest first.
const [cmatDir, file, slug, limit] = process.argv.slice(2);
const { regionsNear } = await import(`${cmatDir}/src/lib/region/neighbours.ts`);
const rows = JSON.parse(await Bun.file(file!).text()).regions;
console.log(JSON.stringify(regionsNear(rows, slug!, limit ? Number(limit) : 16).map((r: { slug: string }) => r.slug)));
