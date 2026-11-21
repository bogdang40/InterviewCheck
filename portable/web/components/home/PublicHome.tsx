"use client"

import Link from "next/link"
import { useEffect, useState } from "react"
import {
  ArrowRight,
  AudioLines,
  Check,
  FileAudio,
  FileDown,
  FileText,
  Keyboard,
  Mic,
  Printer,
  Rows3,
  Sparkles,
  Table2,
} from "lucide-react"
import { PRODUCT_NAME } from "@/lib/brand"
import ReviewFile from "./ReviewFile"
import "@/app/home.css"
import "@/app/home-pages.css"

const tabs = [
  { id: "policy", label: "Policy" },
  { id: "answer", label: "Answer" },
  { id: "sources", label: "Sources" },
  { id: "follow-up", label: "Follow-up" },
  { id: "outcome", label: "Outcome" },
  { id: "report", label: "Report" },
] as const

function useCurrentTab() {
  const [current, setCurrent] = useState<string>(tabs[0].id)
  useEffect(() => {
    const sections = tabs.map((t) => document.getElementById(t.id)).filter(Boolean) as HTMLElement[]
    const io = new IntersectionObserver(
      (entries) => {
        const visible = entries.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)
        if (visible[0]) setCurrent(visible[0].target.id)
      },
      { rootMargin: "-30% 0px -55% 0px" },
    )
    sections.forEach((s) => io.observe(s))
    return () => io.disconnect()
  }, [])
  return current
}

export default function PublicHome() {
  const current = useCurrentTab()

  useEffect(() => {
    const previous = document.title
    document.title = `${PRODUCT_NAME} · See where an answer came from`
    return () => {
      document.title = previous
    }
  }, [])

  return (
    <div className="home">
      <a href="#home-main" className="home-skip">
        Skip to content
      </a>
      <header className="home-bar">
        <Link href="/" className="home-brand" aria-label={`${PRODUCT_NAME} home`}>
          <span className="home-mark">
            <AudioLines size={20} strokeWidth={2.4} aria-hidden="true" />
          </span>
          {PRODUCT_NAME}
        </Link>
        <nav className="home-nav" aria-label="Site">
          <a href="#policy">How it works</a>
          <Link href="/sample/">Sample review</Link>
          <Link href="/account/?next=/" className="home-signin">
            Sign in
          </Link>
        </nav>
      </header>

      <main id="home-main" tabIndex={-1}>
        <section className="home-hero" aria-labelledby="home-title">
          <div className="home-pitch">
            <h1 id="home-title">
              See where an answer <em>came from.</em>
            </h1>
            <p className="home-lede">
              {PRODUCT_NAME} marks every passage of a candidate&rsquo;s answer that matches, word for word, an AI
              answer or any other source you add. Then it drafts the question to ask next. The judgement stays with
              you.
            </p>
            <div className="home-actions">
              <Link href="/account/?next=/" className="home-btn primary">
                Sign in
              </Link>
              <Link href="/sample/" className="home-btn">
                Try the sample review
                <ArrowRight size={16} aria-hidden="true" />
              </Link>
            </div>
            <p className="home-fine">The sample is fictional and needs no account. Workspaces are set up by invitation.</p>
          </div>
          <ReviewFile />
        </section>

        <div className="home-file">
          <nav className="home-tabs" aria-label="How a review works">
            {tabs.map((t) => (
              <a key={t.id} href={`#${t.id}`} aria-current={current === t.id ? "true" : undefined}>
                {t.label}
              </a>
            ))}
          </nav>

          <div className="home-pages">
            <section id="policy" className="home-page" aria-labelledby="policy-h">
              <div className="home-copy">
                <h2 id="policy-h">Agree the rules before the first question.</h2>
                <p>
                  Write down what the candidate may use: notes, a manual, nothing at all. Name the permitted sources
                  and they are left out of every comparison. Record that the candidate knows how their answers will be
                  captured and reviewed before you collect one.
                </p>
              </div>
              <div className="home-sheet">
                <p className="sheet-label">Assistance policy</p>
                <p className="sheet-quote">Notes allowed. No AI tools while answering.</p>
                <p className="sheet-label">Permitted sources</p>
                <p className="sheet-row">
                  <FileText size={15} aria-hidden="true" /> Service manual, chapter 4
                  <span className="sheet-tag">left out of matching</span>
                </p>
                <p className="sheet-check">
                  <Check size={15} aria-hidden="true" /> Candidate notice recorded
                </p>
              </div>
            </section>

            <section id="answer" className="home-page" aria-labelledby="answer-h">
              <div className="home-copy">
                <h2 id="answer-h">Capture the words, however they arrive.</h2>
                <p>
                  Type the answer as you hear it, pick the exchange out of a meeting transcript with its speakers, or
                  capture audio live when a transcription service is connected.
                </p>
              </div>
              <ul className="home-sheet sheet-list">
                <li>
                  <Keyboard size={16} aria-hidden="true" />
                  <span>
                    <b>Typed</b> while you listen
                  </span>
                </li>
                <li>
                  <FileAudio size={16} aria-hidden="true" />
                  <span>
                    <b>Meeting transcript</b> as WebVTT, by speaker
                  </span>
                </li>
                <li>
                  <Mic size={16} aria-hidden="true" />
                  <span>
                    <b>Live audio</b> with your transcription provider
                  </span>
                </li>
              </ul>
            </section>

            <section id="sources" className="home-page" aria-labelledby="sources-h">
              <div className="home-copy">
                <h2 id="sources-h">Compare against what they could have read.</h2>
                <p>
                  Paste the answer an AI assistant gives to the same question, a reference, or a colleague&rsquo;s
                  notes. With a model connected, the workspace can write an AI reference answer for you. Matches count
                  only against sources you have not permitted.
                </p>
              </div>
              <ul className="home-sheet sheet-list">
                <li>
                  <Sparkles size={16} aria-hidden="true" />
                  <span>
                    <b>AI answer</b> to the same question
                  </span>
                  <span className="sheet-tag hot">compared</span>
                </li>
                <li>
                  <FileText size={16} aria-hidden="true" />
                  <span>
                    <b>Reference</b> from the role plan
                  </span>
                  <span className="sheet-tag hot">compared</span>
                </li>
                <li>
                  <FileText size={16} aria-hidden="true" />
                  <span>
                    <b>Service manual</b>
                  </span>
                  <span className="sheet-tag">permitted</span>
                </li>
              </ul>
            </section>

            <section id="follow-up" className="home-page wide" aria-labelledby="follow-h">
              <div className="home-copy">
                <h2 id="follow-h">Ask how they got there.</h2>
                <p>
                  A shared passage is a reason to ask, not an answer. The workspace quotes the candidate back to
                  themselves and drafts the follow-up; you ask it, and save what they say next to the passage.
                </p>
              </div>
              <blockquote className="home-sheet sheet-ask">
                <p>
                  You said &ldquo;We give checkout a separate pool of workers so a slow inventory&rdquo;. Which part
                  would you change under a different constraint, and why?
                </p>
                <footer>Drafted from the shared passage · fictional example</footer>
              </blockquote>
            </section>

            <section id="outcome" className="home-page" aria-labelledby="outcome-h">
              <div className="home-copy">
                <h2 id="outcome-h">You decide what it means.</h2>
                <p>
                  {PRODUCT_NAME} never turns a match into a cheating score. Mark the passage explained, unresolved, or
                  disclosed by the candidate, and write down why.
                </p>
              </div>
              <div className="home-sheet sheet-outcome">
                <p className="sheet-option picked">
                  <span className="dot" aria-hidden="true" /> Explained
                </p>
                <p className="sheet-option">
                  <span className="dot" aria-hidden="true" /> Unresolved
                </p>
                <p className="sheet-option">
                  <span className="dot" aria-hidden="true" /> Candidate disclosed assistance
                </p>
                <p className="sheet-label sheet-note-label">Your note · fictional example</p>
                <p className="sheet-note">
                  &ldquo;Walked through why the pool size was 8 on their last team. Consistent with the answer.&rdquo;
                </p>
              </div>
            </section>

            <section id="report" className="home-page" aria-labelledby="report-h">
              <div className="home-copy">
                <h2 id="report-h">Leave with a record you can stand behind.</h2>
                <p>
                  Print the interview or save it as a PDF, export Markdown, hand a review brief to the panel, put
                  candidates side by side, or export the archive as CSV.
                </p>
              </div>
              <ul className="home-sheet sheet-list">
                <li>
                  <Printer size={16} aria-hidden="true" />
                  <span>
                    <b>Print or PDF</b> with sources and scorecard
                  </span>
                </li>
                <li>
                  <FileDown size={16} aria-hidden="true" />
                  <span>
                    <b>Markdown</b> and a review brief
                  </span>
                </li>
                <li>
                  <Rows3 size={16} aria-hidden="true" />
                  <span>
                    <b>Compare candidates</b> question by question
                  </span>
                </li>
                <li>
                  <Table2 size={16} aria-hidden="true" />
                  <span>
                    <b>CSV archive</b> of every interview
                  </span>
                </li>
              </ul>
            </section>
          </div>
        </div>

        <section className="home-close" aria-labelledby="close-h">
          <h2 id="close-h">
            Evidence, <em>not a verdict.</em>
          </h2>
          <p>No probability, no score. The passage, the source it matches, and the question to ask about it.</p>
          <div className="home-actions">
            <Link href="/sample/" className="home-btn primary">
              Try the sample review
              <ArrowRight size={16} aria-hidden="true" />
            </Link>
            <Link href="/account/?next=/" className="home-btn">
              Sign in
            </Link>
          </div>
        </section>
      </main>

      <footer className="home-foot">
        <span className="home-brand small">
          <span className="home-mark">
            <AudioLines size={16} strokeWidth={2.4} aria-hidden="true" />
          </span>
          {PRODUCT_NAME}
        </span>
        <span>Interview review workspace</span>
        <nav aria-label="Footer">
          <Link href="/sample/">Sample review</Link>
          <Link href="/account/?next=/">Sign in</Link>
        </nav>
      </footer>
    </div>
  )
}
