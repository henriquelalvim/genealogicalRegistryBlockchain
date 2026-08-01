import { network } from "hardhat";
import fs from "node:fs";

const { ethers } = await network.create();
const [a] = await ethers.getSigners();
const YEAR = 365n * 24n * 60n * 60n;

function sizeOf(name: string, sol: string) {
  const p = `artifacts/contracts/${sol}/${name}.json`;
  const art = JSON.parse(fs.readFileSync(p, "utf8"));
  const dep = (art.deployedBytecode?.object ?? art.deployedBytecode ?? "").replace(/^0x/, "");
  return dep.length / 2;
}

const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
const birth = now - 5n * YEAR;
const rows: { stack: string; size: number; founder: bigint; parented: bigint }[] = [];

async function gasOf(tx: any) {
  const r = await (await tx).wait();
  return r!.gasUsed as bigint;
}

// Every stack registers the same three animals: two founders, then a foal naming both.
for (const [label, name] of [
  ["core only", "BenchCore"],
  ["+ Offspring", "BenchOffspring"],
  ["+ LateParentage", "BenchLate"],
  ["+ all modules", "BenchFull"],
] as const) {
  const c = await ethers.deployContract(name);
  const g1 = await gasOf(c.register(a.address, 0n, 0n, true, birth)); // founding sire
  await c.register(a.address, 0n, 0n, false, birth); // founding dam
  const g2 = await gasOf(c.register(a.address, 1n, 2n, false, birth + 100n)); // the foal
  rows.push({ stack: label, size: sizeOf(name, "bench/BenchStacks.sol"), founder: g1, parented: g2 });
}

// The real domain contract, with breeds and the animal record on top.
{
  const c = await ethers.deployContract("PedigreeRegistry", ["P", "P", "Equus caballus", a.address]);
  await c.createBreed("MM", "MM", 1); // Open, so parents of any breed pass
  const g1 = await gasOf(c.register(a.address, 1n, 0n, 0n, true, birth, "", ""));
  await c.register(a.address, 1n, 0n, 0n, false, birth, "", "");
  const g2 = await gasOf(c.register(a.address, 1n, 1n, 2n, false, birth + 100n, "", ""));
  rows.push({
    stack: "PedigreeRegistry",
    size: sizeOf("PedigreeRegistry", "PedigreeRegistry.sol"),
    founder: g1,
    parented: g2,
  });
}

const pad = (s: string, n: number) => s.padEnd(n);
const padl = (s: string, n: number) => s.padStart(n);
console.log(
  "\n| " + pad("stack", 20) + " | " + padl("bytecode", 9) + " | " + padl("founder", 9) + " | " + padl("2 parents", 10) + " |",
);
console.log("|" + "-".repeat(22) + "|" + "-".repeat(11) + "|" + "-".repeat(11) + "|" + "-".repeat(12) + "|");
let prev: (typeof rows)[0] | null = null;
for (const r of rows) {
  const d = prev && r.stack !== "PedigreeRegistry" ? `  (+${r.size - prev.size} bytes, +${r.parented - prev.parented} gas)` : "";
  console.log(
    "| " + pad(r.stack, 20) + " | " + padl(String(r.size), 9) + " | " + padl(String(r.founder), 9) + " | " + padl(String(r.parented), 10) + " |" + d,
  );
  prev = r;
}
console.log();
