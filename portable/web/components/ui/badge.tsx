import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "@/lib/utils"

const badgeVariants = cva(
  "inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-xs font-semibold whitespace-nowrap transition-colors",
  {
    variants: {
      variant: {
        default: "border-[var(--selected-line)] bg-[var(--selected-bg)] text-[var(--green-ink)]",
        secondary: "border-[var(--line)] bg-[var(--subtle)] text-[var(--secondary-ink)]",
        outline: "border-[var(--line)] bg-[var(--surface)] text-[var(--ink)]",
        warning: "border-[var(--warning-line)] bg-[var(--warning-bg)] text-[var(--attention)]",
        destructive: "border-[var(--error-line)] bg-[var(--error-bg)] text-[var(--error-text)]",
        success: "border-[var(--success-line)] bg-[var(--success-bg)] text-[var(--success-text)]",
      },
    },
    defaultVariants: {
      variant: "secondary",
    },
  },
)

function Badge({
  className,
  variant = "secondary",
  ...props
}: React.ComponentProps<"span"> & VariantProps<typeof badgeVariants>) {
  return (
    <span
      data-slot="badge"
      data-variant={variant}
      className={cn(badgeVariants({ variant }), className)}
      {...props}
    />
  )
}

export { Badge, badgeVariants }
