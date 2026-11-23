"use client"

import Link from "next/link"
import { AlertTriangle, LogIn, RotateCcw } from "lucide-react"
import { needsSignIn } from "@/lib/api"
import { signInHrefForCurrentPage } from "@/lib/signInHref"
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
  if (needsSignIn(text)) {
    // Read at render: this branch only appears after a client request fails, never in a prerendered page.
    const signInHref = signInHrefForCurrentPage()
    // Not an error: a signed-out visitor needs a way in, not an alarm and a Retry button.
    return (
      <div className="notice flex flex-wrap items-center justify-between gap-3" role="status">
        <p className="min-w-0 flex-1 text-sm leading-5">Sign in to open your interviews, roles and reports.</p>
        <Button asChild size="sm" className="min-h-11 sm:min-h-8">
          <Link href={signInHref}>
            <LogIn className="size-3.5" aria-hidden="true" />
            Sign in
          </Link>
        </Button>
      </div>
    )
  }
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
