"use client"

import { useEffect, useRef, useState } from "react"
import { AudioLines, Mic, MonitorSpeaker, Square } from "lucide-react"
import { Button } from "./ui/button"
import styles from "./AudioPreflight.module.css"

type Source = "microphone" | "shared"
type Phase = "idle" | "permission" | "checking" | "done"
type Check = {
  stream?: MediaStream
  context?: AudioContext
  source?: MediaStreamAudioSourceNode
  analyser?: AnalyserNode
  interval?: number
  timeout?: number
  peak: number
  ended: () => void
}

const MEASURE_MS = 3000
const SIGNAL_FLOOR_DB = -55

function permissionMessage(error: unknown, source: Source) {
  if (error instanceof DOMException) {
    if (error.name === "NotAllowedError" || error.name === "SecurityError") {
      return "Permission was denied or the picker was cancelled. Start another check to try again."
    }
    if (error.name === "NotFoundError") return "No audio input is available for this source."
    if (error.name === "NotReadableError")
      return "The browser could not read this source. Check the device or sharing selection."
  }
  return `The ${source === "microphone" ? "microphone" : "shared audio"} check failed. ${error instanceof Error ? error.message : "Try another source."}`
}

export default function AudioPreflight({ disabled = false }: { disabled?: boolean }) {
  const [phase, setPhase] = useState<Phase>("idle")
  const [status, setStatus] = useState("")
  const [level, setLevel] = useState(-72)
  const mounted = useRef(true)
  const run = useRef<Check | null>(null)

  function finish(text: string, update = true) {
    const check = run.current
    if (!check) return
    run.current = null
    window.clearInterval(check.interval)
    window.clearTimeout(check.timeout)
    for (const track of check.stream?.getTracks() || []) {
      track.removeEventListener("ended", check.ended)
      track.stop()
    }
    check.source?.disconnect()
    check.analyser?.disconnect()
    if (check.context && check.context.state !== "closed") {
      void check.context.close().catch(() => {
        if (mounted.current && !run.current)
          setStatus("Input tracks stopped. Close this tab to release the audio context.")
      })
    }
    if (update && mounted.current) {
      setPhase("done")
      setStatus(text)
    }
  }

  useEffect(() => {
    mounted.current = true
    const hidden = () => {
      if (document.hidden) finish("Audio check stopped when the tab was hidden.")
    }
    const leaving = () => finish("Audio check stopped.")
    document.addEventListener("visibilitychange", hidden)
    window.addEventListener("pagehide", leaving)
    return () => {
      mounted.current = false
      document.removeEventListener("visibilitychange", hidden)
      window.removeEventListener("pagehide", leaving)
      finish("", false)
    }
  }, [])
  useEffect(() => {
    if (disabled) finish("Audio check stopped.")
  }, [disabled])

  async function start(kind: Source) {
    if (run.current || disabled) return
    const check: Check = {
      peak: -Infinity,
      ended: () => finish("The selected input ended. Start another check to select a source."),
    }
    run.current = check
    setPhase("permission")
    setLevel(-72)
    setStatus(
      kind === "microphone"
        ? "Waiting for microphone permission."
        : "Choose a call tab or surface and enable audio in the picker.",
    )
    check.timeout = window.setTimeout(
      () => finish("Audio selection timed out. Start another check to try again."),
      25000,
    )
    try {
      const devices = navigator.mediaDevices
      if (
        typeof AudioContext === "undefined" ||
        !devices ||
        (kind === "shared" ? !devices.getDisplayMedia : !devices.getUserMedia)
      ) {
        finish("This browser does not support the selected local audio check.")
        return
      }
      // Create and resume within the click gesture. No node connects to the speakers.
      const context = new AudioContext()
      check.context = context
      const resumed = context.resume().catch((error) => {
        if (run.current === check) finish(permissionMessage(error, kind))
      })
      const stream =
        kind === "microphone"
          ? await devices.getUserMedia({ audio: true })
          : await devices.getDisplayMedia({ audio: true, video: true })
      if (run.current !== check) {
        stream.getTracks().forEach((track) => track.stop())
        return
      }
      check.stream = stream
      stream.getTracks().forEach((track) => track.addEventListener("ended", check.ended, { once: true }))
      const audio = stream.getAudioTracks().filter((track) => track.readyState === "live")
      if (!audio.length) {
        finish(
          kind === "shared"
            ? "No audio track was shared. Select a call tab and enable audio."
            : "The microphone returned no live audio track.",
        )
        return
      }
      await resumed
      if (run.current !== check) return
      const source = context.createMediaStreamSource(new MediaStream(audio))
      check.source = source
      const analyser = context.createAnalyser()
      check.analyser = analyser
      analyser.fftSize = 1024
      source.connect(analyser)
      const frame = new Float32Array(analyser.fftSize)
      function sample() {
        analyser.getFloatTimeDomainData(frame)
        let squares = 0
        for (const value of frame) squares += value * value
        const rms = Math.sqrt(squares / frame.length)
        const db = rms > 0 ? 20 * Math.log10(rms) : -Infinity
        check.peak = Math.max(check.peak, db)
        setLevel(Math.max(-72, Math.min(0, db)))
      }
      window.clearTimeout(check.timeout)
      setPhase("checking")
      setStatus(
        kind === "microphone"
          ? "Speak during the three second check."
          : "Play sound in your test call during the three second check.",
      )
      sample()
      check.interval = window.setInterval(sample, 100)
      check.timeout = window.setTimeout(() => {
        const result =
          check.peak >= SIGNAL_FLOOR_DB
            ? `Signal detected. Peak measured level ${Math.round(check.peak)} dBFS.`
            : "No signal measured during the check. The source may have been silent or quiet."
        finish(result)
      }, MEASURE_MS)
    } catch (error) {
      if (run.current === check) finish(permissionMessage(error, kind))
    }
  }

  const active = phase === "permission" || phase === "checking"
  return (
    <details
      className={`panel ${styles.panel}`}
      onToggle={(e) => {
        if (!e.currentTarget.open && run.current) finish("Audio check stopped.")
      }}
    >
      <summary>
        <AudioLines aria-hidden size={16} />
        Audio preflight
      </summary>
      <div className="stack">
        <p>
          Test your own voice or a test call before the interview. This optional check measures input level in
          this tab.
        </p>
        <div className="row">
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={active || disabled}
            onClick={() => start("microphone")}
          >
            <Mic />
            Test microphone
          </Button>
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={active || disabled}
            onClick={() => start("shared")}
          >
            <MonitorSpeaker />
            Test shared call audio
          </Button>
          {active && (
            <Button type="button" size="sm" variant="ghost" onClick={() => finish("Audio check stopped.")}>
              <Square />
              Stop audio check
            </Button>
          )}
        </div>
        {phase === "checking" && (
          <label className={styles.level}>
            Input level
            <meter min={-72} max={0} value={level} aria-label="Input level in dBFS" />
          </label>
        )}
        {status && <p role="status">{status}</p>}
      </div>
    </details>
  )
}
