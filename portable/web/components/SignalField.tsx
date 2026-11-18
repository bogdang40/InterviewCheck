"use client"

import { useEffect, useRef } from "react"

// Both renderers use the same signal surface so the still image survives a lost GPU context.
function height(x: number, z: number, phase: number) {
  const path = x - z * 0.58
  const envelope = Math.exp((-path * path) / 6.8)
  return envelope * (Math.cos(path * 1.65 + phase) * 0.69 + Math.sin(z * 1.6 - phase) * 0.28 + 0.3)
}

export default function SignalField() {
  const host = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = host.current
    if (!el) return
    let closed = false
    let cleanup = () => {}
    void import("three").then((T) => {
      if (closed) return
      let renderer: InstanceType<typeof T.WebGLRenderer>
      try {
        renderer = new T.WebGLRenderer({ alpha: true, antialias: true })
      } catch {
        return
      }
      el.appendChild(renderer.domElement)
      const scene = new T.Scene()
      const camera = new T.OrthographicCamera(-4, 4, 2, -2, 0.1, 100)
      camera.position.set(2.2, 2.4, 6)
      camera.lookAt(0, 0.15, 0)
      const lines = Array.from({ length: 62 }, (_, i) => {
        const geometry = new T.BufferGeometry()
        const position = new T.BufferAttribute(new Float32Array(129 * 3), 3)
        geometry.setAttribute("position", position)
        const material = new T.LineBasicMaterial({
          color: new T.Color().setHSL(0.36 + i * 0.0011, 0.55, 0.58 + 0.18 * Math.sin((i / 62) * Math.PI)),
          transparent: true,
          opacity: 0.78,
        })
        const line = new T.Line(geometry, material)
        line.frustumCulled = false
        scene.add(line)
        return { geometry, position, material, z: (i / 61 - 0.5) * 4.6 }
      })
      function render(phase: number) {
        for (const { position, z } of lines) {
          for (let j = 0; j < position.count; j++) {
            const x = (j / 128 - 0.5) * 8.0
            position.setXYZ(j, x, height(x, z, phase), z)
          }
          position.needsUpdate = true
        }
        renderer.render(scene, camera)
      }
      const reduced = window.matchMedia("(prefers-reduced-motion: reduce)")
      let frame = 0
      let last = 0
      let visible = true
      function tick(time: number) {
        if (time - last > 55) {
          render(Math.sin(time / 8000) * 0.4)
          last = time
        }
        frame = requestAnimationFrame(tick)
      }
      function update() {
        cancelAnimationFrame(frame)
        render(0)
        if (visible && !reduced.matches && !document.hidden) frame = requestAnimationFrame(tick)
      }
      function resize() {
        if (!el) return
        const { width, height } = el.getBoundingClientRect()
        if (!width || !height) return
        const halfHeight = 2.1
        camera.left = (-halfHeight * width) / height
        camera.right = -camera.left
        camera.top = halfHeight
        camera.bottom = -halfHeight
        camera.updateProjectionMatrix()
        renderer.setPixelRatio(Math.min(devicePixelRatio, 1.5))
        renderer.setSize(width, height)
        render(0)
      }
      const sizes = new ResizeObserver(resize)
      sizes.observe(el)
      const visibility = new IntersectionObserver(([entry]) => {
        visible = entry.isIntersecting
        update()
      })
      visibility.observe(el)
      reduced.addEventListener("change", update)
      document.addEventListener("visibilitychange", update)
      resize()
      el.dataset.ready = "true"
      cleanup = () => {
        cancelAnimationFrame(frame)
        reduced.removeEventListener("change", update)
        document.removeEventListener("visibilitychange", update)
        sizes.disconnect()
        visibility.disconnect()
        for (const { geometry, material } of lines) {
          geometry.dispose()
          material.dispose()
        }
        renderer.dispose()
        renderer.domElement.remove()
        delete el.dataset.ready
      }
    })
    return () => {
      closed = true
      cleanup()
    }
  }, [])
  return (
    <div className="signal-field" ref={host} aria-hidden="true">
      <svg viewBox="0 0 500 250" preserveAspectRatio="xMidYMid slice">
        {Array.from({ length: 44 }, (_, i) => {
          const z = (i / 43 - 0.5) * 4.6
          const points = Array.from({ length: 95 }, (_, j) => {
            const x = (j / 94 - 0.5) * 8
            return `${250 + x * 64 - z * 17},${120 + z * 20 - height(x, z, 0) * 78 - x * 4}`
          })
          return (
            <polyline key={i} points={points.join(" ")} fill="none" stroke="#8edbad" strokeWidth="1.05" />
          )
        })}
      </svg>
    </div>
  )
}
