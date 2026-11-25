// The persona hook: how a bot plays. The client and the game flow call a Strategy and never
// decide an answer or a vote themselves, so a persona (an LLM player, a cheater, a last-second
// player) is a new Strategy, with nothing else changed. Both methods may be async.
import { pick, type Rng } from "./rng.js";
import { wordsFor, type WordLists } from "./words.js";

export interface RoundContext {
  round: number;
  letter: string;
  category: { id: string; name: string };
  /** Epoch ms on the server's clock. */
  deadline: number;
  serverNow: number;
  me: { playerId: string; index: number };
  words: WordLists;
  rng: Rng;
}

export interface PlannedAnswer {
  text: string;
  /** How long after round:start arrived to send it. */
  afterMs: number;
}

export interface VoteContext {
  round: number;
  item: { playerId: string; nickname: string; answer: string };
  me: { playerId: string; index: number };
  rng: Rng;
}

export interface Strategy {
  readonly name: string;
  /** A nickname the game accepts: 2–16 Hebrew or Latin letters, digits, spaces, - _ '. */
  nickname(index: number): string;
  /** The answer for this round, or null for none. */
  answer(ctx: RoundContext): PlannedAnswer | null | Promise<PlannedAnswer | null>;
  /** Accept (true) or reject (false) another player's answer, or abstain (null). */
  vote(ctx: VoteContext): boolean | null | Promise<boolean | null>;
}

const HEBREW = "אבגדהוזחטיכלמנסעפצקרשת";

export interface ScriptedOptions {
  /** Share of rounds answered with a word from the list; the rest split between made-up words and no answer. */
  valid: number;
  invalid: number;
  /** Share of votes that accept. */
  accept: number;
}

/**
 * The default player: mostly real words from the lists, sometimes a made-up word that starts with
 * the right letter (the validator rejects it, or the room votes on it), sometimes nothing. It
 * answers between 20% and 70% of the way through the round.
 */
export function scripted(opts: ScriptedOptions = { valid: 0.75, invalid: 0.15, accept: 0.5 }): Strategy {
  return {
    name: "scripted",
    nickname: (index) => `בוט ${index + 1}`,
    answer(ctx) {
      const roll = ctx.rng();
      const remaining = Math.max(0, ctx.deadline - ctx.serverNow);
      const afterMs = Math.round(remaining * (0.2 + 0.5 * ctx.rng()));
      if (roll < opts.valid) {
        const word = pick(ctx.rng, wordsFor(ctx.words, ctx.category.id, ctx.letter));
        if (word) return { text: word, afterMs };
      }
      if (roll < opts.valid + opts.invalid) {
        let text = ctx.letter;
        for (let i = 0; i < 5; i++) text += HEBREW[Math.floor(ctx.rng() * HEBREW.length)];
        return { text, afterMs };
      }
      return null;
    },
    vote: (ctx) => ctx.rng() < opts.accept,
  };
}

const STRATEGIES: Record<string, () => Strategy> = { scripted: () => scripted() };

export const strategyNames = Object.keys(STRATEGIES);

export function strategyByName(name: string): Strategy {
  const make = STRATEGIES[name];
  if (!make) throw new Error(`unknown strategy "${name}"`);
  return make();
}
