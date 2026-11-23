import { dateLabel } from "@/lib/api"
import type { CompareSessionSummary } from "@/lib/compareInterviews"
import styles from "./CompareDossierView.module.css"

export default function ComparisonScorecards({ sessions, includeRationales }: {
  sessions: CompareSessionSummary[]
  includeRationales: boolean
}) {
  return (
    <section className={styles.section} aria-labelledby="saved-scorecards-heading">
      <h2 id="saved-scorecards-heading" tabIndex={-1}>Saved interview scorecards</h2>
      <p className="muted">Each weighted score uses the criteria, ratings and weights saved for that interview.</p>
      <div className={styles.cardsGrid}>
        {sessions.map(({ id, candidate, role, created_at, scorecard }) => (
          <article key={id} className={`panel ${styles.candidateCard}`} aria-labelledby={`scorecard-${id}`}>
            <header>
              <h3 id={`scorecard-${id}`}>{candidate || "Unnamed candidate"}</h3>
              <p className={styles.cardMeta}>{role || "No role assigned"} · {dateLabel(created_at)}</p>
            </header>
            {!scorecard ? <p className="muted">Saved scorecard unavailable.</p>
              : !scorecard.rated_count ? <p className="muted">No saved ratings.</p>
              : <>
                <p className={styles.cardMeta}>
                  {scorecard.weighted_score_pct !== null && <><strong>{scorecard.weighted_score_pct}%</strong> weighted score across </>}
                  {scorecard.rated_count}{" "}
                  {scorecard.rated_count === 1 ? "rated criterion" : "rated criteria"}
                </p>
                <ol className={styles.scoreItems} role="list">
                  {scorecard.items.map(item => (
                    <li key={item.criterion_id}>
                      <strong>{item.criterion_label}</strong>
                      <p className={styles.cardMeta}>Rating {item.rating} of 5 · Weight {item.weight}</p>
                      {includeRationales && item.rationale && <p className={styles.rationale}>
                        <strong>Reviewer rationale</strong> {item.rationale}
                      </p>}
                    </li>
                  ))}
                </ol>
              </>}
          </article>
        ))}
      </div>
    </section>
  )
}
