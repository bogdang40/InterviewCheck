"use client"

import Link from "next/link"
import { useEffect } from "react"
import { ArrowLeft, AudioLines } from "lucide-react"
import { PRODUCT_NAME } from "@/lib/brand"
import "@/app/home.css"
import "@/app/signin.css"

/** The public frame around /account/ for a signed-out visitor of a hosted deployment. */
export default function SignInFrame({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    const previous = document.title
    document.title = `Sign in · ${PRODUCT_NAME}`
    return () => {
      document.title = previous
    }
  }, [])

  return (
    <div className="home signin">
      <header className="home-bar">
        <Link href="/" className="home-brand" aria-label={`${PRODUCT_NAME} home`}>
          <span className="home-mark">
            <AudioLines size={20} strokeWidth={2.4} aria-hidden="true" />
          </span>
          {PRODUCT_NAME}
        </Link>
        <nav className="home-nav" aria-label="Site">
          <Link href="/">
            <ArrowLeft size={15} aria-hidden="true" className="signin-back" />
            Home
          </Link>
          <Link href="/sample/">Sample review</Link>
        </nav>
      </header>
      <main id="main-content" className="signin-main" tabIndex={-1}>
        {children}
      </main>
    </div>
  )
}
