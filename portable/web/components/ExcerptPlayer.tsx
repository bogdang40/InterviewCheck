"use client"

import { useEffect, useLayoutEffect, useRef, useState } from "react"
import { Pause, Play } from "lucide-react"
import { Button } from "./ui/button"
import type { TranscriptOrigin } from "@/lib/api"
import styles from "./LocalRecordingPlayback.module.css"

const VIDEO_EXTENSION = /\.(mp4|m4v|webm|mov|ogv)$/i

type Mode = "ready" | "starting" | "playing" | "paused" | "finished"

export function ExcerptPlayer({
  file,
  origin,
  selectedId,
  disabled,
}: {
  file: File
  origin?: TranscriptOrigin
  selectedId?: string
  disabled: boolean
}) {
  const media = useRef<HTMLMediaElement | null>(null)
  const operation = useRef(0)
  const timer = useRef<number | undefined>(undefined)
  const timeout = useRef<number | undefined>(undefined)
  const active = useRef(false)
  const [duration, setDuration] = useState<number | null>(null)
  const [mode, setMode] = useState<Mode>("ready")
  const [sourceError, setSourceError] = useState("")
  const [playError, setPlayError] = useState("")
  const video = file.type.startsWith("video/") || (!file.type && VIDEO_EXTENSION.test(file.name))
  const start = (origin?.start_ms ?? 0) / 1000
  const end = (origin?.end_ms ?? 0) / 1000

  function stop(next: Mode) {
    operation.current++
    active.current = false
    window.clearTimeout(timer.current)
    window.clearTimeout(timeout.current)
    media.current?.pause()
    setMode(next)
  }

  useLayoutEffect(() => {
    stop("ready")
    setPlayError("")
    return () => {
      operation.current++
      active.current = false
      media.current?.pause()
      window.clearTimeout(timer.current)
      window.clearTimeout(timeout.current)
    }
  }, [selectedId, disabled, start, end])

  useEffect(() => {
    const node = media.current
    if (!node) return
    let url: string
    try {
      url = URL.createObjectURL(file)
    } catch {
      setSourceError("The browser could not open this local file.")
      return
    }
    node.src = url
    node.load()
    function hide() {
      if (document.hidden && active.current) stop("paused")
    }
    const waitForMetadata = window.setTimeout(() => {
      if (node.readyState < 1)
        setSourceError("The browser could not read the recording duration. Select another file.")
    }, 10000)
    let released = false
    function release() {
      if (released) return
      released = true
      window.clearTimeout(waitForMetadata)
      operation.current++
      active.current = false
      window.clearTimeout(timer.current)
      window.clearTimeout(timeout.current)
      node!.pause()
      node!.removeAttribute("src")
      node!.load()
      URL.revokeObjectURL(url)
    }
    document.addEventListener("visibilitychange", hide)
    window.addEventListener("pagehide", release)
    return () => {
      document.removeEventListener("visibilitychange", hide)
      window.removeEventListener("pagehide", release)
      release()
    }
  }, [file])

  function enforceEnd() {
    const node = media.current
    if (!node || !active.current || node.paused) return
    window.clearTimeout(timer.current)
    const remaining = end - node.currentTime
    if (remaining <= 0) {
      stop("finished")
      // Browsers deliver time events at different cadences. Return the frame to the exact endpoint.
      if (node.currentTime > end) node.currentTime = end
      return
    }
    timer.current = window.setTimeout(enforceEnd, Math.max(10, (remaining * 1000) / (node.playbackRate || 1)))
  }

  async function play() {
    const node = media.current
    if (!node || disabled || !origin || !duration || end > duration + 0.0005 || end <= start) return
    const token = ++operation.current
    const position =
      mode === "paused" && node.currentTime >= start && node.currentTime < end ? node.currentTime : start
    setPlayError("")
    setMode("starting")
    active.current = true
    try {
      const seekable = node.seekable
      if (
        seekable.length &&
        !Array.from({ length: seekable.length }, (_, i) => i).some(
          (i) => position >= seekable.start(i) - 0.001 && position <= seekable.end(i) + 0.001,
        )
      ) {
        throw new Error("The selected interval cannot be reached in this recording.")
      }
      node.currentTime = position
      timeout.current = window.setTimeout(() => {
        if (operation.current !== token) return
        stop("ready")
        setPlayError(
          "The recording did not start at the selected time. Check its format or select another file.",
        )
      }, 10000)
      await node.play()
      if (operation.current !== token) return
      window.clearTimeout(timeout.current)
      if (node.currentTime + 0.05 < position)
        throw new Error("The browser could not seek to the transcript time.")
      setMode("playing")
      enforceEnd()
    } catch (error) {
      if (operation.current !== token) return
      stop("ready")
      setPlayError(
        error instanceof Error ? error.message : "Playback failed. Try a supported recording format.",
      )
    }
  }

  let issue = ""
  if (origin && end <= start) issue = "This exchange has no playable duration."
  else if (duration !== null && (!Number.isFinite(duration) || duration <= 0))
    issue = "This recording has no measurable duration."
  else if (origin && duration !== null && end > duration + 0.0005)
    issue = "The transcript interval extends beyond this recording."
  function metadata() {
    if (media.current && media.current.readyState >= 1) setDuration(media.current.duration)
  }
  const events = {
    autoPlay: false,
    preload: "metadata",
    disableRemotePlayback: true,
    onLoadedMetadata: metadata,
    onDurationChange: metadata,
    onTimeUpdate: enforceEnd,
    onPlaying: enforceEnd,
    onRateChange: enforceEnd,
    onPause: () => {
      if (active.current) stop("paused")
    },
    onEnded: () => {
      stop("finished")
    },
    onError: () => {
      if (!media.current?.getAttribute("src")) return
      stop("ready")
      setSourceError("This browser could not read the recording. Select another file or codec.")
    },
  }
  const running = mode === "playing" || mode === "starting"
  return (
    <div className="stack">
      {video ? (
        <video
          ref={(el) => {
            media.current = el
          }}
          {...events}
          disablePictureInPicture
          playsInline
          className={styles.video}
          aria-label="Selected local video"
        />
      ) : (
        <audio
          ref={(el) => {
            media.current = el
          }}
          {...events}
          className={styles.audio}
          aria-label="Selected local audio"
        />
      )}
      {sourceError || playError || issue ? (
        <p role="alert" className="error">
          {sourceError || playError || issue}
        </p>
      ) : null}
      {origin && (
        <div className="row">
          {running ? (
            <Button type="button" size="sm" variant="outline" onClick={() => stop("paused")}>
              <Pause />
              Pause excerpt
            </Button>
          ) : (
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={disabled || duration === null || !!issue || !!sourceError}
              onClick={play}
            >
              <Play />
              {mode === "paused" ? "Resume excerpt" : mode === "finished" ? "Replay excerpt" : "Play excerpt"}
            </Button>
          )}
          {mode === "finished" && (
            <span role="status" className="muted">
              End of exchange
            </span>
          )}
        </div>
      )}
    </div>
  )
}
