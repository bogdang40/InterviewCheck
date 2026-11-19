import type { ComponentProps } from "react"
import { Slot } from "@radix-ui/react-slot"
import { cn } from "@/lib/utils"

function Card({ asChild, className, ...props }: ComponentProps<"div"> & { asChild?: boolean }) {
  const Component = asChild ? Slot : "div"
  return <Component data-slot="card" className={cn("panel", className)} {...props} />
}

function CardHeader({ className, ...props }: ComponentProps<"div">) {
  return <div data-slot="card-header" className={cn("card-header", className)} {...props} />
}

export { Card, CardHeader }
