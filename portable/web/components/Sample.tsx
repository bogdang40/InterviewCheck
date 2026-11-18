import { useEffect, useRef, useState } from "react"
import { FlaskConical, Plus, RotateCcw } from "lucide-react"
import { api, message, type Answer, type Disposition } from "@/lib/api"
import { practiceCases } from "@/lib/sample"
import { Button } from "./ui/button"
import { Textarea } from "./ui/textarea"
import MarkedText from "./MarkedText"
import { Findings } from "./Evidence"
import QuestionNavigator from "./QuestionNavigator"

const blankNotes=()=>practiceCases.map(()=>({note:"",disposition:"pending" as Disposition}))

export default function Sample({create}:{create:()=>void}) {
  const [selected,setSelected]=useState(0),[overrides,setOverrides]=useState<Record<string,boolean>>({})
  const [notes,setNotes]=useState(blankNotes),[results,setResults]=useState<Answer["result"][]>()
  const [error,setError]=useState(""),[retry,setRetry]=useState(0)
  const cache=useRef(new Map<string, Answer["result"]>())
  const scenario=practiceCases[selected]
  const key=(source:number)=>scenario.id+"."+source
  function sourcesFor(id:string) {
    const item=practiceCases.find(c=>c.id===id)!
    return item.sources.map((source,i)=>({...source,permitted:overrides[id+"."+i]??source.permitted}))
  }
  useEffect(()=>{
    const controller=new AbortController()
    setResults(undefined);setError("")
    Promise.all(practiceCases.map(async c=>{
      const references=c.sources.map((source,i)=>({...source,permitted:overrides[c.id+"."+i]??source.permitted}))
      const signature=JSON.stringify([c.id,references.map(r=>r.permitted)])
      const saved=cache.current.get(signature)
      if(saved) return saved
      const result=await api<Answer["result"]>("preview","POST",{question:c.question,answer:c.answer,references},controller.signal)
      if(!controller.signal.aborted) cache.current.set(signature,result)
      return result
    })).then(items=>{if(!controller.signal.aborted)setResults(items)}).catch(e=>{if(!controller.signal.aborted)setError(message(e))})
    return ()=>controller.abort()
  },[overrides,retry])
  const answers:Answer[]=results?practiceCases.map((c,i)=>({
    id:c.id,revision:1,question:c.question,answer:c.answer,references:sourcesFor(c.id),result:results[i],...notes[i],
  })):[]
  const item=answers[selected],sources=sourcesFor(scenario.id)
  function changeNote(update:Partial<ReturnType<typeof blankNotes>[number]>){setNotes(old=>old.map((n,i)=>i===selected?{...n,...update}:n))}
  function reset(){setSelected(0);setOverrides({});setNotes(blankNotes());setRetry(n=>n+1)}
  return <>
    <div className="page-title spread"><div><span className="eyebrow"><FlaskConical size={14}/> FICTIONAL SESSION</span>
      <h1>Sample review</h1><p>Practice on three exchanges. Your selections and notes stay in this tab until you leave.</p></div>
      <div className="row"><Button size="sm" variant="outline" onClick={reset}><RotateCcw/>Reset sample</Button><Button onClick={create}><Plus/>New interview</Button></div></div>
    {error && <div role="alert" className="error">{error} <Button variant="outline" onClick={()=>setRetry(x=>x+1)}>Retry</Button></div>}
    {item?<div className="review-grid"><QuestionNavigator answers={answers} active={item.id} disabled={false} onSelect={a=>setSelected(answers.findIndex(x=>x.id===a.id))}/>
      <article className="panel evidence"><span className="eyebrow">{scenario.topic.toUpperCase()}</span><h2>{item.question}</h2>
        <p className="transcript-text"><MarkedText text={item.answer} passages={item.result.passages}/></p>
        {sources.map((s,i)=><div className="source-box" key={s.label}><b>{s.label}</b><p><MarkedText text={s.text} side="source" passages={item.result.passages.filter(p=>p.source_index===i)}/></p>
          <label className="check"><input type="checkbox" checked={s.permitted} onChange={e=>{const flag=e.target.checked;setOverrides(o=>({...o,[key(i)]:flag}));changeNote({disposition:"pending"})}}/>
            {sources.length===1?"Permitted material":"Permit "+s.label}</label></div>)}
        <Findings result={item.result}/>
        <div className="stack"><label className="field">Practice outcome<select value={item.disposition} onChange={e=>changeNote({disposition:e.target.value as Disposition})}>
          <option value="pending">Pending review</option><option value="explained">Explained</option><option value="unresolved">Unresolved</option></select></label>
          <label className="field">Practice note<Textarea maxLength={12000} value={item.note} onChange={e=>changeNote({note:e.target.value})}/></label>
          <small className="muted">{notes.filter(n=>n.disposition!=="pending").length} of {answers.length} practice outcomes recorded.</small></div>
      </article></div>:!error && <p role="status">Comparing the practice exchanges…</p>}
  </>
}
