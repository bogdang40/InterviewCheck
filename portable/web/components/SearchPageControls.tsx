import { Button } from "./ui/button"

export default function SearchPageControls({ label, page, hasNext, previous, next }: {
  label: string; page: number; hasNext: boolean; previous: () => void; next: () => void
}) {
  if (page === 1 && !hasNext) return null
  return <nav className="search-page-controls" aria-label={label}>
    <Button type="button" size="sm" variant="outline" disabled={page === 1} onClick={previous}>Previous results</Button>
    <Button type="button" size="sm" variant="outline" disabled={!hasNext} onClick={next}>Next results</Button>
  </nav>
}
