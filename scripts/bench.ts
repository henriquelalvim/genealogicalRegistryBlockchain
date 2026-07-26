import { network } from "hardhat";
import fs from "node:fs";

const { ethers } = await network.create();
const [a, b] = await ethers.getSigners();
const YEAR = 365n * 24n * 60n * 60n;

function sizeOf(name: string, sol: string) {
  const p = `artifacts/contracts/${sol}/${name}.json`;
  const art = JSON.parse(fs.readFileSync(p, "utf8"));
  const dep = (art.deployedBytecode?.object ?? art.deployedBytecode ?? "").replace(/^0x/, "");
  return dep.length / 2;
}

const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
const birth = now - 5n * YEAR;
const rows: { stack: string; size: number; regNoParents: bigint; regTwoParents: bigint }[] = [];

async function gasOf(tx: any) {
  const r = await (await tx).wait();
  return r!.gasUsed as bigint;
}

// ── dateless stacks ──
for (const [label, name] of [["core only", "BenchCore"], ["+ Offspring", "BenchOffspring"], ["+ LinkApproval", "BenchApproval"]] as const) {
  const c = await ethers.deployContract(name);
  const g1 = await gasOf(c.register(a.address, 0n, 0n, true));   // founder, no parents
  await c.register(a.address, 0n, 0n, false);                     // a dam
  const g2 = await gasOf(c.register(a.address, 1n, 2n, false));   // child with both parents
  rows.push({ stack: label, size: sizeOf(name, "bench/BenchStacks.sol"), regNoParents: g1, regTwoParents: g2 });
}

// ── dated stacks ──
for (const [label, name] of [["+ Dated", "BenchDated"], ["+ all modules", "BenchFull"]] as const) {
  const c = await ethers.deployContract(name);
  const g1 = await gasOf(c.register(a.address, 0n, 0n, true, birth));
  await c.register(a.address, 0n, 0n, false, birth);
  const g2 = await gasOf(c.register(a.address, 1n, 2n, false, birth + 100n));
  rows.push({ stack: label, size: sizeOf(name, "bench/BenchStacks.sol"), regNoParents: g1, regTwoParents: g2 });
}

// ── the real domain contract ──
{
  const c = await ethers.deployContract("PedigreeRegistry", ["P", "P", "Equus caballus", a.address]);
  await c.createBreed("MM", "MM", 1); // Open, so parents of any breed pass
  const g1 = await gasOf(c.register(a.address, 1n, 0n, 0n, true, birth, "", ""));
  await c.register(a.address, 1n, 0n, 0n, false, birth, "", "");
  const g2 = await gasOf(c.register(a.address, 1n, 1n, 2n, false, birth + 100n, "", ""));
  rows.push({ stack: "PedigreeRegistry (modular)", size: sizeOf("PedigreeRegistry", "PedigreeRegistry.sol"), regNoParents: g1, regTwoParents: g2 });
}

const pad = (s: string, n: number) => s.padEnd(n);
const padl = (s: string, n: number) => s.padStart(n);
console.log("\n| " + pad("stack", 28) + " | " + padl("bytecode", 9) + " | " + padl("register (no parents)", 21) + " | " + padl("register (2 parents)", 20) + " |");
console.log("|" + "-".repeat(30) + "|" + "-".repeat(11) + "|" + "-".repeat(23) + "|" + "-".repeat(22) + "|");
let prev: typeof rows[0] | null = null;
for (const r of rows) {
  const d = prev && !r.stack.startsWith("Pedigree") ? `  (+${r.size - prev.size})` : "";
  console.log("| " + pad(r.stack, 28) + " | " + padl(String(r.size), 9) + " | " + padl(String(r.regNoParents), 21) + " | " + padl(String(r.regTwoParents), 20) + " |" + d);
  prev = r;
}
console.log();
