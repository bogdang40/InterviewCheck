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
  const [value, setValue] = useState<Preference>("system")
  const id = useId()
  useEffect(() => {
    const sync = () => {
      const theme = document.documentElement.dataset.theme
      setValue(theme === "light" || theme === "dark" ? theme : "system")
    }
    sync()
    window.addEventListener("interviewcheck:appearance", sync)
    return () => window.removeEventListener("interviewcheck:appearance", sync)
  }, [])
  function select(preference: Preference) {
    document.documentElement.dataset.theme = preference
    try {
      localStorage.setItem("interviewcheck.appearance", preference)
    } catch {
      /* Applies for the current page if storage is unavailable. */
    }
    setValue(preference)
  }
  return (
    <section className="panel data-panel appearance">
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
