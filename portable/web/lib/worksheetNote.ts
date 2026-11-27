export const MAX_NOTE_CHARACTERS = 12_000

// ReviewInput strips Unicode White_Space before validating and storing the note.
export function normalizedWorksheetNote(raw: string): string {
  return raw.replace(/^\p{White_Space}+|\p{White_Space}+$/gu, "")
}
