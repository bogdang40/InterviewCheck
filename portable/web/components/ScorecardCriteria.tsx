import type { ScoreConflict } from "@/lib/scorecardDraft"
import type { ScorecardItem } from "@/lib/sessionScorecard"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"
import styles from "./SessionScorecardPanel.module.css"

function ScoreValue({ row }: { row?: ScorecardItem }) {
  if (!row) return <p>Criterion removed.</p>
  return <div className={styles.scoreValue}>
    <p>{row.criterion_label} · Weight {row.weight} · {row.rating === null ? "Unrated" : `${row.rating} of 5`}</p>
    <p>{row.rationale || "No rationale entered."}</p>
  </div>
}

export default function ScorecardCriteria({ rows, added, invalid, conflicts, savedRatings, removals, markRemoval, prefix, update, remove, choose }: {
  rows: ScorecardItem[]
  added: Set<string>
  invalid: Set<string>
  conflicts: ScoreConflict[]
  savedRatings: Set<string>
  removals: ReadonlyMap<string, ScorecardItem>
  markRemoval: (id: string, remove: boolean) => void
  prefix: string
  update: (id: string, patch: Partial<ScorecardItem>) => void
  remove: (id: string) => void
  choose: (conflict: ScoreConflict, selection: "local" | "saved") => void
}) {
  const blocked = new Set(conflicts.map((conflict) => conflict.id))
  return <>
    {conflicts.map((conflict, index) => {
      const label = conflict.local?.criterion_label ?? conflict.saved?.criterion_label
      return <fieldset className={styles.criterionCard} key={conflict.id}>
        <legend>Resolve changes to {label}</legend>
        <div className={styles.comparison}>
          <div><strong>Current saved score</strong><ScoreValue row={conflict.saved} /></div>
          <div><strong>Your draft</strong>{conflict.removeLocal ? <p>Remove the rating and rationale.</p> : <ScoreValue row={conflict.local} />}</div>
        </div>
        <div className={styles.ratingGroup}>
          <Button id={index === 0 ? `${prefix}-resolve` : undefined} type="button" size="sm" variant="outline"
            onClick={() => choose(conflict, "saved")}>Use saved score</Button>
          <Button type="button" size="sm" variant="outline" onClick={() => choose(conflict, "local")}>
            {conflict.removeLocal ? "Keep removal" : "Keep my draft"}
          </Button>
        </div>
      </fieldset>
    })}
    {rows.length === 0 && <p className="muted">Add a criterion below to grade this interview.</p>}
    <ul className={styles.criteriaList}>
      {rows.map((row) => {
        const id = row.criterion_id
        const unrated = invalid.has(id)
        const hint = `${prefix}-error-${id}`
        if (removals.has(id)) return <li key={id} className={styles.criterionCard}>
          <strong>{row.criterion_label}</strong>
          <p>Saving will remove this rating and its rationale.</p>
          <div><Button id={`${prefix}-undo-${id}`} type="button" size="sm" variant="outline" disabled={blocked.has(id)}
            aria-label={`Undo removal of ${row.criterion_label}`} onClick={() => markRemoval(id, false)}>Undo removal</Button></div>
        </li>
        return <li key={id} className={styles.criterionCard}>
          <div className={styles.criterionTop}>
            <div><strong>{row.criterion_label}</strong> <span className={styles.weightLabel}>Weight {row.weight}</span></div>
            <div className={styles.ratingGroup} role="group" aria-label={`Rating for ${row.criterion_label}`} aria-describedby={unrated ? hint : undefined}>
              {[1, 2, 3, 4, 5].map((rating) => <button type="button" key={rating} className={styles.ratingBtn}
                id={rating === 1 ? `${prefix}-rate-${id}` : undefined} disabled={blocked.has(id)}
                aria-pressed={row.rating === rating} aria-label={`Rate ${row.criterion_label} ${rating} of 5`}
                aria-describedby={unrated ? hint : undefined} onClick={() => update(id, { rating })}>{rating}</button>)}
            </div>
          </div>
          <label className="field">Rationale for {row.criterion_label}
            <Textarea rows={2} value={row.rationale} maxLength={2000} disabled={blocked.has(id)}
              placeholder="Document observed signals or gaps..." onChange={(event) => update(id, { rationale: event.target.value })} />
          </label>
          {unrated && <p className="error" id={hint}>Choose a rating to save this criterion.</p>}
          {added.has(id) && !blocked.has(id) && <div><Button type="button" variant="ghost" size="sm"
            aria-label={`Discard new criterion ${row.criterion_label}`} onClick={() => remove(id)}>Discard new criterion</Button></div>}
          {savedRatings.has(id) && !blocked.has(id) && <div><Button id={`${prefix}-remove-${id}`} type="button" variant="ghost" size="sm"
            aria-label={`Remove saved rating for ${row.criterion_label}`} onClick={() => markRemoval(id, true)}>Remove saved rating</Button></div>}
        </li>
      })}
    </ul>
  </>
}
