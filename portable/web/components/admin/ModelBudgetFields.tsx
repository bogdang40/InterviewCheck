"use client"

import { useId } from "react"
import { Input } from "@/components/ui/input"
import { readBudgetParameters, type ModelBudgetParameters } from "@/lib/adminDiagnostics"
import { parseOptionalFloat, parseOptionalInt, type ConnectedModel } from "@/lib/adminModels"

const monthlyThresholdLabel = "Monthly estimated spend threshold (USD)"

export type ModelBudgetValues = {
  dailyTokenLimit: string
  monthlyCostLimitUsd: string
  inputCostPer1mUsd: string
  outputCostPer1mUsd: string
}

export function initialBudgetValues(editing: ConnectedModel | null): ModelBudgetValues {
  const budget = readBudgetParameters(editing?.parameters)
  return {
    dailyTokenLimit: budget.daily_token_limit != null ? String(budget.daily_token_limit) : "",
    monthlyCostLimitUsd:
      budget.monthly_cost_limit_usd != null ? String(budget.monthly_cost_limit_usd) : "",
    inputCostPer1mUsd:
      budget.input_cost_per_1m_usd != null ? String(budget.input_cost_per_1m_usd) : "",
    outputCostPer1mUsd:
      budget.output_cost_per_1m_usd != null ? String(budget.output_cost_per_1m_usd) : "",
  }
}

export function parseModelBudgetValues(values: ModelBudgetValues): Required<ModelBudgetParameters> {
  return {
    daily_token_limit: parseOptionalInt(
      values.dailyTokenLimit,
      "Daily token limit",
      1,
      100000000,
    ),
    monthly_cost_limit_usd: parseOptionalFloat(
      values.monthlyCostLimitUsd,
      monthlyThresholdLabel,
      0.01,
      100000,
    ),
    input_cost_per_1m_usd: parseOptionalFloat(
      values.inputCostPer1mUsd,
      "Input cost per 1M tokens (USD)",
      0,
      1000,
    ),
    output_cost_per_1m_usd: parseOptionalFloat(
      values.outputCostPer1mUsd,
      "Output cost per 1M tokens (USD)",
      0,
      1000,
    ),
  }
}

export function ModelBudgetFields({
  values,
  busy,
  onChange,
}: {
  values: ModelBudgetValues
  busy: boolean
  onChange: (next: ModelBudgetValues) => void
}) {
  const thresholdId = useId()
  return (
    <fieldset className="admin-budget-fieldset">
      <legend>Model budgets and token rates (optional)</legend>
      <div className="admin-param-grid">
        <label className="field">
          Daily token limit (1 to 100M)
          <Input
            type="number"
            step="1"
            min="1"
            max="100000000"
            disabled={busy}
            value={values.dailyTokenLimit}
            placeholder="Unlimited"
            onChange={(e) => onChange({ ...values, dailyTokenLimit: e.target.value })}
          />
        </label>
        <div className="field">
          <label htmlFor={thresholdId}>{monthlyThresholdLabel}</label>
          <Input
            id={thresholdId}
            aria-describedby={`${thresholdId}-help`}
            type="number"
            step="0.01"
            min="0.01"
            max="100000"
            disabled={busy}
            value={values.monthlyCostLimitUsd}
            placeholder="No threshold"
            onChange={(e) => onChange({ ...values, monthlyCostLimitUsd: e.target.value })}
          />
          <small className="muted" id={`${thresholdId}-help`}>
            Enter $0.01 to $100,000. Once the recorded estimate for this model reaches this amount in a UTC month,
            InterviewCheck skips the model on later budget checks. Provider charges can exceed this amount.
            A request already in progress can take the recorded estimate above this amount.
          </small>
        </div>
        <label className="field">
          Input USD per 1M tokens
          <Input
            type="number"
            step="0.0001"
            min="0"
            max="1000"
            disabled={busy}
            value={values.inputCostPer1mUsd}
            placeholder="0.00"
            onChange={(e) => onChange({ ...values, inputCostPer1mUsd: e.target.value })}
          />
        </label>
        <label className="field">
          Output USD per 1M tokens
          <Input
            type="number"
            step="0.0001"
            min="0"
            max="1000"
            disabled={busy}
            value={values.outputCostPer1mUsd}
            placeholder="0.00"
            onChange={(e) => onChange({ ...values, outputCostPer1mUsd: e.target.value })}
          />
        </label>
      </div>
    </fieldset>
  )
}
