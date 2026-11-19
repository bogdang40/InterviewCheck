"use client"

import { Laptop, Moon, Sun } from "lucide-react"
import { useEffect, useId, useState } from "react"

type Preference = "system" | "light" | "dark"
const choices = [
  { value: "system", label: "System", Icon: Laptop },
  { value: "light", label: "Light", Icon: Sun },
  { value: "dark", label: "Dark", Icon: Moon },
] as const

export default function Appearance() {
  const [value, setValue] = useState<Preference>("dark")
  const [hydrated, setHydrated] = useState(false)
  const id = useId()
  useEffect(() => {
    const sync = () => {
      let stored: string | null = null
      try {
        stored = localStorage.getItem("interviewcheck.appearance")
      } catch {
        stored = null
      }
      const raw =
        stored === "light" || stored === "system" || stored === "dark"
          ? stored
          : document.documentElement.dataset.theme
      const resolved: Preference = raw === "light" || raw === "system" ? raw : "dark"
      document.documentElement.dataset.theme = resolved
      setValue(resolved)
    }
    sync()
    setHydrated(true)
    window.addEventListener("interviewcheck:appearance", sync)
    return () => window.removeEventListener("interviewcheck:appearance", sync)
  }, [])
  function select(preference: Preference) {
    try {
      localStorage.setItem("interviewcheck.appearance", preference)
    } catch {
      /* Applies for the current page if storage is unavailable. */
    }
    document.documentElement.dataset.theme = preference
    setValue(preference)
  }
  return (
    <section
      className="panel data-panel appearance"
      data-hydrated={hydrated ? "true" : "false"}
    >
      <h2>Appearance</h2>
      <fieldset>
        <legend>Color theme for this browser</legend>
        <div>
          {choices.map(({ value: choice, label, Icon }) => (
            <label key={choice}>
              <input type="radio" name={id} checked={choice === value} onChange={() => select(choice)} />
              <Icon size={16} />
              {label}
            </label>
          ))}
        </div>
      </fieldset>
    </section>
  )
}
