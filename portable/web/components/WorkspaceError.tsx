"use client"

import Link from "next/link"
import { AlertTriangle, RotateCcw } from "lucide-react"
import { Button } from "./ui/button"

type WorkspaceErrorProps = {
  text: string
  retry: () => void
  retryLabel?: string
  showAccount?: boolean
}

export default function WorkspaceError({
  text,
  retry,
  retryLabel = "Retry",
  showAccount = true,
}: WorkspaceErrorProps) {
  return (
    <div
      className="error flex flex-wrap items-center justify-between gap-3"
      role="alert"
      aria-live="assertive"
    >
      <div className="flex min-w-0 items-start gap-2.5">
        <AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
        <p className="min-w-0 flex-1 text-sm leading-5">{text}</p>
      </div>
      <div className="flex flex-wrap items-center gap-2.5">
        <Button type="button" size="sm" variant="outline" className="min-h-11 sm:min-h-8" onClick={retry}>
          <RotateCcw className="size-3.5" aria-hidden="true" />
          {retryLabel}
        </Button>
        {showAccount && (
          <Link
            href="/account/"
            className="inline-flex min-h-11 items-center rounded-md px-2.5 text-sm font-medium focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring sm:min-h-8"
          >
            Account
          </Link>
        )}
      </div>
    </div>
  )
}
