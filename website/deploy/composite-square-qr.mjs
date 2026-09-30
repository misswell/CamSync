import { readFile, writeFile } from "node:fs/promises";

const background = (await readFile("website/public/assets/promos/square/camsync-square-03-download-art.png")).toString("base64");
const qr = (await readFile("website/public/assets/app-store-qr.svg")).toString("base64");
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1254" height="1254" viewBox="0 0 1254 1254"><image x="0" y="0" width="1254" height="1254" preserveAspectRatio="none" href="data:image/png;base64,${background}"/><image x="405" y="535" width="444" height="444" href="data:image/svg+xml;base64,${qr}"/></svg>`;
await writeFile("/tmp/camsync-square-03-qr.svg", svg);
