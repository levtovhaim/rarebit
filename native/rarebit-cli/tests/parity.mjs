// Parity: rarebit-cli's `check --json` against the running validator, on the same answers.
// Run by parity.sh inside the bots image (Node) on the local stack's network. Reads the word lists
// from /cli/data, generates answers from every word (as listed, with niqqud, spelling variants,
// one-letter typos, wrong letters, edge cases), asks both, and reports every difference.
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";

const VALIDATOR = process.env.VALIDATOR_URL ?? "http://validator:8080";
const CLI = "/cli/rarebit-cli";
const DATA = "/cli/data"; // the word lists the CLI reads
// Where the answers come from: the same lists, unless a negative control gives the CLI different
// ones (then the answers must still come from the lists the validator has).
const CASES = process.env.PARITY_CASES ?? DATA;
const LETTERS = [..."אבגדהוזחטיכלמנסעפצקרשת"];
const FINAL = { "ך": "כ", "ם": "מ", "ן": "נ", "ף": "פ", "ץ": "צ" };

const firstLetter = (word) => {
  const c = [...word][0];
  return FINAL[c] ?? c;
};

function cases() {
  const out = [];
  for (const file of readdirSync(CASES).filter((f) => f.endsWith(".json")).sort()) {
    const cat = JSON.parse(readFileSync(`${CASES}/${file}`, "utf8"));
    for (const list of cat.lists) {
      for (const word of list.words) {
        const letter = firstLetter(word);
        if (!LETTERS.includes(letter)) continue;
        const chars = [...word];
        const add = (answer, l = letter) => out.push({ category: cat.id, letter: l, answer });
        add(word); // exact
        add(chars[0] + "ָ" + chars.slice(1).join("")); // with a kamatz
        const vy = chars.findIndex((c, i) => i > 0 && i < chars.length - 1 && (c === "ו" || c === "י"));
        if (vy > 0) add(chars.filter((_, i) => i !== vy).join("")); // without one vav/yod of full spelling
        if (chars.length > 2) add(chars[0] + "ו" + chars.slice(1).join("")); // an extra vav
        if (chars.length > 3) {
          add(chars.slice(0, -1).join("") + (chars.at(-1) === "א" ? "ה" : "א")); // last letter replaced
          add(chars.slice(0, -1).join("")); // last letter dropped
          add(chars.slice(0, 2).join("") + "ש" + chars.slice(2).join("")); // a letter inserted
        }
        add(word, LETTERS[(LETTERS.indexOf(letter) + 1) % LETTERS.length]); // the wrong letter
      }
    }
  }
  out.push(
    { category: "animal", letter: "א", answer: "" },
    { category: "animal", letter: "א", answer: "!?" },
    { category: "animal", letter: "א", answer: "א".repeat(64) },
    { category: "animal", letter: "א", answer: "א".repeat(65) },
    { category: "animal", letter: "א", answer: "abc" },
    { category: "animal", letter: "א", answer: "<&>" },
    { category: "animal", letter: "ך", answer: "כלב" },
    { category: "animal", letter: "a", answer: "כלב" },
    { category: "no-such-category", letter: "א", answer: "אריה" },
    { category: "Bad/../id", letter: "א", answer: "אריה" },
  );
  return out;
}

async function validator(c) {
  const res = await fetch(`${VALIDATOR}/v1/validate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(c),
  });
  const body = await res.json();
  return res.status === 200 ? { status: 200, ...body } : { status: res.status, error: body.error };
}

function cli(c) {
  const r = spawnSync(CLI, ["check", "--data", DATA, "--json", c.category, c.letter, "--", c.answer], {
    encoding: "utf8",
  });
  if (r.error) throw r.error;
  if (r.status === 0 || r.status === 1) {
    const body = JSON.parse(r.stdout);
    if ((r.status === 0) !== (body.result === "valid")) throw new Error(`exit ${r.status} for ${r.stdout}`);
    return { status: 200, ...body };
  }
  if (r.status === 2) {
    const error = /unknown category/.test(r.stderr) ? "unknown_category" : /final form/.test(r.stderr) ? "bad_letter" : "usage";
    return { status: 400, error };
  }
  throw new Error(`exit ${r.status}: ${r.stderr}`);
}

const fields = ["status", "error", "result", "reason", "match", "entry", "key"];
const all = cases();
let same = 0;
const entryOnly = [];
const different = [];
const byResult = {};
for (const c of all) {
  const v = await validator(c);
  const l = cli(c);
  const tag = v.status === 200 ? `${v.result}${v.match ? "/" + v.match : ""}${v.reason ? "/" + v.reason : ""}` : `http ${v.status}`;
  byResult[tag] = (byResult[tag] ?? 0) + 1;
  const diff = fields.filter((f) => (v[f] ?? "") !== (l[f] ?? ""));
  if (diff.length === 0) same++;
  else if (diff.length === 1 && diff[0] === "entry" && v.match === l.match) entryOnly.push({ c, v: v.entry, l: l.entry });
  else different.push({ c, v, l });
}
console.log(`cases: ${all.length}, identical: ${same}, entry ties: ${entryOnly.length}, different: ${different.length}`);
console.log(`by the validator's verdict: ${JSON.stringify(byResult)}`);
for (const e of entryOnly.slice(0, 10)) console.log(`entry tie: ${JSON.stringify(e)}`);
for (const d of different.slice(0, 10)) console.log(`DIFFERENT: ${JSON.stringify(d)}`);
process.exit(different.length === 0 ? 0 : 1);
