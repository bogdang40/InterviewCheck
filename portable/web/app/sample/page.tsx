"use client"

import Sample from "@/components/Sample"
import { usePreparation } from "@/lib/workspace"
export default function SamplePage() {
  const { prepare } = usePreparation()
  return <Sample create={() => prepare()} />
}
