import dynamic from "next/dynamic"
import { useEffect, useRef, type ComponentProps } from "react"
import { Button } from "./ui/button"

type EditorProps = ComponentProps<typeof import("./AnswerEditor").default>

function EditorUnavailable({ onCancel, initial }: EditorProps) {
  const title = useRef<HTMLHeadingElement>(null)
  useEffect(() => {
    if (document.activeElement === document.body) title.current?.focus()
  }, [])
  return <section className="panel inset stack" aria-label="Exchange editor unavailable">
    <h2 ref={title} tabIndex={-1}>Exchange editor unavailable</h2>
    <p role="alert">The editor could not load. Reload this interview to open the editor.</p>
    <div className="row">
      <Button type="button" onClick={() => window.location.reload()}>Reload interview</Button>
      <Button type="button" variant="outline" onClick={onCancel}>
        {initial ? "Return to saved exchange" : "Return to interview"}
      </Button>
    </div>
  </section>
}

export default dynamic<EditorProps>(() => import("./AnswerEditor").catch((error: unknown) => {
  // The production webpack loader reports the failed script URL on ChunkLoadError.
  if (error instanceof Error && error.name === "ChunkLoadError" && "request" in error &&
      typeof error.request === "string" && /\/_next\/static\/chunks\/[^?#]+\.js(?:[?#]|$)/.test(error.request)) {
    return { default: EditorUnavailable }
  }
  throw error
}), {
  ssr: false,
  loading: () => <p role="status">Loading exchange editor...</p>,
})
