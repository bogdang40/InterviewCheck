import { AudioLines } from "lucide-react"
import type { Answer } from "@/lib/api"
import MarkedText from "./MarkedText"

export default function CandidateResponse({ item }: { item: Answer }) {
  return <>
    <span className="response-label"><AudioLines size={15} aria-hidden="true"/>Candidate response</span>
    <p className="transcript-text"><MarkedText text={item.answer} passages={item.result.passages}/></p>
  </>
}
