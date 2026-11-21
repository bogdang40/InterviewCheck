import type { Metadata } from "next"
import InterviewList from "@/components/InterviewList"
import { PRODUCT_NAME } from "@/lib/brand"
import site from "@/lib/site.json"

// What link previews and search engines read for the site address. deploy/Dockerfile writes the
// public origin into lib/site.json before building, so the preview image gets an absolute URL.
const origin = site.origin
const title = `${PRODUCT_NAME} · See where an answer came from`
const description =
  `${PRODUCT_NAME} marks every passage of a candidate's answer that matches an AI answer or another source ` +
  "word for word, and drafts the follow-up question. Evidence, not a verdict."
// public/og-home.png is a 1200x630 screenshot of the home page's first viewport; retake it after a rename.
const image = { url: "/og-home.png", width: 1200, height: 630, alt: `${PRODUCT_NAME} home page: an answer and the AI answer it shares 18 words with` }

export const metadata: Metadata = {
  ...(origin ? { metadataBase: new URL(origin) } : {}),
  title,
  description,
  openGraph: { title, description, type: "website", siteName: PRODUCT_NAME, images: [image] },
  twitter: { card: "summary_large_image", title, description, images: [image.url] },
}

export default function Overview() {
  return <InterviewList />
}
