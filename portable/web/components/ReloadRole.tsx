import type { Role } from "@/lib/api"
import { useResource } from "@/lib/workspace"
import { Button } from "./ui/button"

export default function ReloadRole({ id, label, onLoad }: {
  id: string
  label: string
  onLoad: (role: Role) => void
}) {
  const saved = useResource<Role>("roles/" + encodeURIComponent(id))
  if (saved.error) return <div>
    <p role="alert" className="error">{saved.error}</p>
    <Button type="button" variant="outline" onClick={saved.reload}>Retry loading saved role</Button>
  </div>
  return <Button type="button" variant="outline" disabled={!saved.data}
    onClick={() => { if (saved.data) onLoad(saved.data) }}>{label}</Button>
}
