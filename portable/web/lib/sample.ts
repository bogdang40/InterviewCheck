import type { Source } from "./api"
// The fictional cases live beside the API so the public sample endpoint (api/sample.py)
// compares exactly the text this page shows.
import data from "../../api/sample_cases.json"

export type PracticeCase = { id: string; topic: string; question: string; answer: string; sources: Source[] }

export const practiceCases: PracticeCase[] = data.cases
export const samplePassage: string = data.samplePassage
export const sampleQuestion = practiceCases[0].question
export const sampleAnswer = practiceCases[0].answer
export const sampleSources = practiceCases[0].sources
