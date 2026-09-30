import { readFile, writeFile } from "node:fs/promises";

const poster = (await readFile("website/public/assets/promos/camsync-poster-03-download.png")).toString("base64");
const qr = (await readFile("website/public/assets/app-store-qr.svg")).toString("base64");
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1122" height="1402" viewBox="0 0 1122 1402"><image x="0" y="0" width="1122" height="1402" preserveAspectRatio="none" href="data:image/png;base64,${poster}"/><image x="334" y="602" width="454" height="454" href="data:image/svg+xml;base64,${qr}"/></svg>`;
await writeFile("/tmp/camsync-poster-03-qr-composite.svg", svg);
