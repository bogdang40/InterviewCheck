import type { Source } from "./api"

export const sampleQuestion = "How would you keep a slow dependency from taking down the checkout service?"
export const samplePassage =
  "We give checkout a separate pool of workers so a slow inventory lookup cannot consume every available connection."
export const sampleAnswer = `I would start by isolating inventory. ${samplePassage} Then I would measure how long customers wait during recovery.`
export const sampleSources: Source[] = [
  {
    label: "Practice answer",
    text: `Start by limiting the blast radius. ${samplePassage} A timeout places a bound on the wait.`,
    permitted: false,
  },
]
