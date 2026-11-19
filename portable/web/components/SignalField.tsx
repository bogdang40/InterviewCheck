"use client"

import { useEffect, useRef, useSyncExternalStore } from "react"

// Both renderers use the same signal surface so the still image survives a lost canvas context.
function height(x: number, z: number, phase: number) {
  const path = x - z * 0.58
  const envelope = Math.exp((-path * path) / 6.8)
  return envelope * (Math.cos(path * 1.65 + phase) * 0.69 + Math.sin(z * 1.6 - phase) * 0.28 + 0.3)
}

// Narrow screens use the still surface to keep the interview controls responsive.
const motionQuery = "(prefers-reduced-motion: no-preference) and (min-width: 651px)"
function observeMotion(listener: () => void) {
  const query = window.matchMedia(motionQuery)
  query.addEventListener("change", listener)
  return () => query.removeEventListener("change", listener)
}
const canAnimate = () => window.matchMedia(motionQuery).matches
const still = () => false

const TARGET_Y = 0.15
const [BX, BY] = (() => {
  const dx = 2.2
  const dy = 2.4 - TARGET_Y
  const dz = 6
  const zLen = Math.hypot(dx, dy, dz)
  const bz: [number, number, number] = [dx / zLen, dy / zLen, dz / zLen]
  const xLen = Math.hypot(bz[2], bz[0])
  const bx: [number, number, number] = [bz[2] / xLen, 0, -bz[0] / xLen]
  const by: [number, number, number] = [-bz[1] * bx[2], bz[2] * bx[0] - bz[0] * bx[2], bz[1] * bx[0]]
  return [bx, by]
})()

const CURVES = Array.from({ length: 40 }, (_, i) => ({
  z: (i / 39 - 0.5) * 4.6,
  color: `hsla(${(23.4 + i * 0.162).toFixed(2)}, 58%, ${(49 + 12 * Math.sin((i / 40) * Math.PI)).toFixed(2)}%, 0.72)`,
}))

export default function SignalField() {
  const host = useRef<HTMLDivElement>(null)
  const animate = useSyncExternalStore(observeMotion, canAnimate, still)

  useEffect(() => {
    const el = host.current
    if (!el || !animate) return
    const canvas = document.createElement("canvas")
    const ctx = canvas.getContext("2d")
    if (!ctx) return
    el.appendChild(canvas)

    let width = 0
    let cssHeight = 0
    let frame = 0
    let last = 0
    let visible = true

    function render(phase: number) {
      if (!ctx || !width || !cssHeight) return
      ctx.clearRect(0, 0, width, cssHeight)
      const scale = cssHeight / 4.2
      const halfW = width * 0.5
      const halfH = cssHeight * 0.5
      ctx.lineWidth = 1.05
      for (const curve of CURVES) {
        ctx.beginPath()
        ctx.strokeStyle = curve.color
        const z = curve.z
        const zbx = z * BX[2]
        const zby = z * BY[2]
        for (let j = 0; j < 129; j++) {
          const x = (j / 128 - 0.5) * 8.0
          const y = height(x, z, phase) - TARGET_Y
          const cx = halfW + (x * BX[0] + zbx) * scale
          const cy = halfH - (x * BY[0] + y * BY[1] + zby) * scale
          if (j === 0) ctx.moveTo(cx, cy)
          else ctx.lineTo(cx, cy)
        }
        ctx.stroke()
      }
    }

    function tick(time: number) {
      if (time - last > 55) {
        render(Math.sin(time / 5900) * 0.64)
        last = time
      }
      frame = requestAnimationFrame(tick)
    }

    function update() {
      cancelAnimationFrame(frame)
      if (!visible || document.hidden) return
      frame = requestAnimationFrame(tick)
    }

    function resize() {
      if (!el || !ctx) return
      const rect = el.getBoundingClientRect()
      if (!rect.width || !rect.height) return
      width = rect.width
      cssHeight = rect.height
      const dpr = Math.min(window.devicePixelRatio || 1, 1.5)
      canvas.width = Math.round(width * dpr)
      canvas.height = Math.round(cssHeight * dpr)
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      render(0)
    }

    const sizes = new ResizeObserver(resize)
    sizes.observe(el)
    const visibility = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting
      update()
    })
    visibility.observe(el)
    document.addEventListener("visibilitychange", update)
    resize()
    el.dataset.ready = "true"
    update()

    return () => {
      cancelAnimationFrame(frame)
      document.removeEventListener("visibilitychange", update)
      sizes.disconnect()
      visibility.disconnect()
      canvas.remove()
      delete el.dataset.ready
    }
  }, [animate])

  return (
    <div className="signal-field" ref={host} aria-hidden="true">
      <svg viewBox="0 0 500 250" preserveAspectRatio="xMidYMid slice">
        {Array.from({ length: 30 }, (_, i) => {
          const z = (i / 29 - 0.5) * 4.6
          const points = Array.from({ length: 73 }, (_, j) => {
            const x = (j / 72 - 0.5) * 8
            // Subpixel precision is enough for the static fallback at any UI size.
            const px = (250 + x * 64 - z * 17).toFixed(1)
            const py = (120 + z * 20 - height(x, z, 0) * 78 - x * 4).toFixed(1)
            return `${px},${py}`
          })
          return (
            <polyline key={i} points={points.join(" ")} fill="none" stroke="#b67e56" strokeWidth="1.05" />
          )
        })}
      </svg>
    </div>
  )
}
