"""Explain differences between validated backup records without disclosing their values."""

SESSION_GROUPS = {
    "interview_details": ("id", "candidate", "role", "role_id", "planned_questions", "policy",
                          "permitted_sources", "consent", "created_at", "ended_at", "trashed_at", "tags", "legacy"),
    "assignment": ("assignment",),
    "handoff_notes": ("handoff_notes",),
    "scorecard_items": ("scorecard_items", "rubric_snapshot"),
    "exchanges": ("answers", "review_events"),
    "draft": ("draft",),
}
ROLE_GROUPS = {
    "role_template": ("id", "name", "description", "questions", "policy", "permitted_sources", "legacy"),
    "rubric": ("rubric",),
    "role_history": ("version_number", "versions"),
}


def changed_sections(group, stored, incoming):
    groups = ROLE_GROUPS if group == "roles" else SESSION_GROUPS
    reasons = []
    fields = set(type(incoming).model_fields)
    for code, names in groups.items():
        if any(getattr(stored, name) != getattr(incoming, name) for name in names if name in fields):
            reasons.append(code)
        fields.difference_update(names)
    # A future field can differ alongside a recognized change. Never return
    # that field's name, its nested path, or any part of either record's value.
    if any(getattr(stored, name) != getattr(incoming, name) for name in fields) or not reasons:
        reasons.append("other_changes")
    return reasons
