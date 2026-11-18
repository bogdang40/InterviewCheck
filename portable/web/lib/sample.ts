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

const handbook = "Technicians isolate the battery before opening the enclosure and test both terminals with an independent meter."
export const practiceCases = [
  {id:"checkout", topic:"System design", question:sampleQuestion, answer:sampleAnswer, sources:sampleSources},
  {id:"manual", topic:"Permitted reference", question:"How would you verify that the enclosure is safe to open?",
    answer:handbook+" I would document the reading and the isolation point.",
    sources:[{label:"Practice answer",text:handbook+" Keep a written record.",permitted:false},
      {label:"Permitted service manual",text:handbook,permitted:true}]},
  {id:"migration", topic:"Missing comparison source", question:"Which measurement changed your rollout plan?",
    answer:"At our staging site I compared the oldest pending message before and after restarting the slow consumer. The queue recovered faster when we limited concurrent retries.",
    sources:[]},
] satisfies {id:string;topic:string;question:string;answer:string;sources:Source[]}[]
