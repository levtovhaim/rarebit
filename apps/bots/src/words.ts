// The word lists the scripted bots answer from: data/categories/*.json, the files the validator
// loads. category id -> first letter -> words.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export type WordLists = Map<string, Map<string, string[]>>;

interface CategoryFile {
  id: string;
  lists: Array<{ words: string[] }>;
}

export function loadWords(dir: string): WordLists {
  const files = readdirSync(dir).filter((f) => f.endsWith(".json"));
  if (files.length === 0) throw new Error(`no category files in ${dir}`);
  const out: WordLists = new Map();
  for (const file of files) {
    const category = JSON.parse(readFileSync(join(dir, file), "utf8")) as CategoryFile;
    const byLetter = new Map<string, string[]>();
    for (const word of category.lists.flatMap((l) => l.words)) {
      const letter = [...word][0];
      if (!letter) continue;
      byLetter.set(letter, [...(byLetter.get(letter) ?? []), word]);
    }
    out.set(category.id, byLetter);
  }
  return out;
}

export function wordsFor(words: WordLists, category: string, letter: string): string[] {
  return words.get(category)?.get(letter) ?? [];
}
