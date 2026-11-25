// Every player-facing string, in Hebrew. Code and comments stay in English (CLAUDE.md → Conventions).
import type { ResultLine } from "./protocol";

/** What each error code the game sends means to a player, and what to do about it. */
export const ERRORS: Record<string, string> = {
  bad_request: "משהו בבקשה לא תקין. רעננו את הדף ונסו שוב.",
  rate_limited: "יותר מדי פעולות ברצף. נסו שוב בעוד רגע.",
  bad_nickname: "כינוי צריך 2–16 אותיות בעברית או באנגלית, ספרות או רווחים.",
  nickname_blocked: "הכינוי הזה לא מתאים למשחק. בחרו כינוי אחר.",
  nickname_taken: "הכינוי כבר תפוס בחדר הזה. בחרו כינוי אחר.",
  not_found: "אין חדר עם הקוד הזה. בדקו את הקוד ונסו שוב.",
  room_full: "החדר מלא: אפשר עד 8 שחקנים.",
  already_started: "המשחק בחדר הזה כבר התחיל.",
  bad_token: "אי אפשר לחזור לחדר הזה מהמכשיר הזה.",
  not_in_room: "אתם כבר לא בחדר.",
  not_host: "רק מי שפתח את החדר יכול להתחיל את המשחק.",
  not_enough_players: "צריך לפחות שני שחקנים כדי להתחיל.",
  not_allowed: "אי אפשר לעשות את זה עכשיו.",
  not_accepting: "הזמן נגמר: התשובה לא נקלטה.",
  too_late: "הזמן נגמר: התשובה לא נקלטה.",
  not_playing: "נפסלתם בסיבוב קודם, אז אין צורך לענות. הנקודות שלכם נשמרות.",
  not_voting: "ההצבעה כבר נגמרה.",
  draining: "השרת מתחלף. מתחברים מחדש…",
  busy: "עומס רגעי. נסו שוב.",
  unavailable: "יש תקלה בשרת. נסו שוב בעוד רגע.",
  too_many_connections: "יותר מדי חיבורים מהרשת הזאת. סגרו לשוניות אחרות של המשחק.",
  connect_failed: "אין חיבור לשרת. בדקו את האינטרנט ונסו שוב.",
};

export function errorText(code: string | undefined): string {
  return (code && ERRORS[code]) || ERRORS.unavailable!;
}

export const T = {
  tagline: "ארץ עיר לטלפון. התשובה הנדירה מנצחת.",
  exampleLabel: "דוגמה: האות ב׳, ותשובה לכל קטגוריה",
  nicknameLabel: "הכינוי שלכם",
  nicknamePlaceholder: "למשל: נועה…",
  createRoom: "פתיחת חדר",
  createRoomHint: "לשחק עם חברים: מקבלים קוד ושולחים אותו",
  quickplay: "משחק מהיר",
  quickplayHint: "לשחק עם מי שמחכה עכשיו",
  joinTitle: "יש לכם קוד?",
  codeLabel: "קוד חדר",
  join: "הצטרפות",
  roomCode: "קוד החדר",
  scanToJoin: "סורקים ומצטרפים",
  shareLink: "שליחת קישור",
  linkCopied: "הקישור הועתק",
  players: (n: number, max: number) => `שחקנים · ${n} מתוך ${max}`,
  host: "פתח/ה את החדר",
  you: "את/ה",
  offline: "מנותק/ת",
  startGame: "התחלת המשחק",
  needTwo: "צריך לפחות שני שחקנים",
  waitingForHost: "מחכים שמי שפתח את החדר יתחיל",
  lookingForPlayers: "מחפשים עוד שחקנים…",
  quickplayNeeds: "המשחק מתחיל כשמצטרפים מספיק שחקנים. אפשר לחכות כאן.",
  startsIn: "המשחק מתחיל בעוד",
  leave: "יציאה מהחדר",
  round: (n: number, of: number) => `סיבוב ${n} מתוך ${of}`,
  points: (n: number) => `${n} נק׳`,
  category: "קטגוריה",
  letter: "אות",
  answerLabel: (category: string, letter: string) => `${category} ב־${letter}׳`,
  answerPlaceholder: "התשובה שלכם…",
  working: "רגע…",
  leaveConfirm: "לצאת מהמשחק? הנקודות שלכם נשמרות, אבל לא תוכלו לחזור לחדר הזה.",
  send: "שליחה",
  sent: (answer: string) => `נשלחה: ${answer}`,
  canChange: "אפשר לשנות עד שהזמן נגמר",
  timeUp: "הזמן נגמר",
  secondsLeft: (n: number) => `נותרו ${n} שניות`,
  eliminated: "נפסלתם אחרי שלוש פסילות. הנקודות שלכם נשמרות, ואפשר עדיין לנצח.",
  waitingForCategories: "מחכים לקטגוריות. ממשיכים בעוד רגע…",
  voteTitle: "הצבעה",
  voteQuestion: (category: string, letter: string) => `זו תשובה טובה ל${category} ב־${letter}׳?`,
  accept: "מקבלים",
  reject: "פוסלים",
  yourAnswerIsVoted: "על התשובה שלכם מצביעים האחרים",
  voted: (accept: boolean) => (accept ? "הצבעתם: מקבלים" : "הצבעתם: פוסלים"),
  noOneToVote: "אין על מה להצביע",
  resultsTitle: (round: number) => `תוצאות סיבוב ${round}`,
  nextRoundIn: "הסיבוב הבא בעוד",
  strike: "פסילה",
  standings: "טבלה",
  gameOver: "המשחק נגמר",
  winner: "במקום הראשון",
  tie: "תיקו במקום הראשון",
  playAgain: "למשחק חדש",
  reconnecting: "החיבור נפל. מתחברים מחדש…",
  serverSwitching: "השרת מתחלף. מתחברים מחדש…",
  lostTitle: "אי אפשר לחזור לחדר",
  lostBody: "אולי המשחק נגמר, או שהחדר נסגר.",
  backHome: "לדף הבית",
  tryAgain: "לנסות שוב",
  connecting: "מתחברים…",
} as const;

/** A result line's verdict as a mark and a word: never by color alone. */
export function verdictText(line: Pick<ResultLine, "verdict" | "final">): { mark: string; word: string } {
  switch (line.verdict) {
    case "valid":
      return { mark: "✓", word: "נכון" };
    case "invalid":
      return { mark: "✗", word: "לא נכון" };
    case "unknown":
      return line.final === "valid" ? { mark: "✓", word: "התקבל בהצבעה" } : { mark: "✗", word: "נדחה בהצבעה" };
    case "empty":
      return { mark: "–", word: "בלי תשובה" };
    case "blocked":
      return { mark: "⊘", word: "נחסם" };
  }
}
