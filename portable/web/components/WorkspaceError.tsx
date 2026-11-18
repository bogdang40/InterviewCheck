"use client"

import Link from "next/link"
import { Button } from "./ui/button"

export default function WorkspaceError({ text, retry }: { text: string; retry: () => void }) {
  return (
    <div className="error row" role="alert">
      {text}
      <Button size="sm" variant="outline" onClick={retry}>
        Retry
      </Button>
      <Link href="/account/">Account</Link>
    </div>
  )
}
