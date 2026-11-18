import { Plus, Trash2 } from "lucide-react"
import type { PermittedMaterial } from "@/lib/api"
import { Button } from "./ui/button"
import { Input } from "./ui/input"
import { Textarea } from "./ui/textarea"

type Props = {
  policy: string
  materials: PermittedMaterial[]
  required?: boolean
  onPolicy: (policy: string) => void
  onMaterials: (items: PermittedMaterial[]) => void
}

export default function ResourcePolicy({
  policy,
  materials,
  required = false,
  onPolicy,
  onMaterials,
}: Props) {
  function update(index: number, field: keyof PermittedMaterial, value: string) {
    onMaterials(materials.map((item, position) => (position === index ? { ...item, [field]: value } : item)))
  }
  return (
    <>
      <label className="field">
        Assistance policy
        <Textarea
          name="policy"
          maxLength={4000}
          required={required}
          value={policy}
          onChange={(event) => onPolicy(event.target.value)}
          placeholder="Which tools, notes or references may the candidate use?"
        />
      </label>
      <fieldset className="source-box stack">
        <legend>Permitted sources</legend>
        <p className="muted">Matching passages from these sources are excluded throughout the interview.</p>
        {materials.map((item, index) => (
          <fieldset className="stack" key={index}>
            <legend>Source {index + 1}</legend>
            <label className="field">
              Permitted source name
              <Input
                value={item.label}
                maxLength={180}
                required
                onChange={(e) => update(index, "label", e.target.value)}
              />
            </label>
            <label className="field">
              Permitted source text
              <Textarea
                value={item.text}
                maxLength={12000}
                required
                onChange={(e) => update(index, "text", e.target.value)}
              />
            </label>
            <div>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                aria-label={`Remove permitted source ${index + 1}`}
                onClick={() => onMaterials(materials.filter((_, i) => i !== index))}
              >
                <Trash2 />
                Remove source
              </Button>
            </div>
          </fieldset>
        ))}
        <div>
          <Button
            type="button"
            variant="outline"
            size="sm"
            disabled={materials.length >= 8}
            onClick={() => onMaterials([...materials, { label: "", text: "" }])}
          >
            <Plus />
            Add permitted source
          </Button>
          {materials.length >= 8 && <small> Eight sources added.</small>}
        </div>
      </fieldset>
    </>
  )
}
