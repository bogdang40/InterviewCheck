"""Describe implemented operations using credential presence without contacting vendors."""

from fastapi import APIRouter

from . import access, account_stripe, ats, ats_notes, authoring, booking_sources, mailbox, oauth_tokens
from .provider_http import configured

router = APIRouter()
NAMES = {
    "ashby": "Ashby",
    "bamboohr": "BambooHR",
    "greenhouse": "Greenhouse",
    "jobadder": "JobAdder",
    "kombo": "Kombo",
    "lever": "Lever",
    "merge": "Merge",
    "personio": "Personio",
    "recruitee": "Recruitee",
    "smartrecruiters": "SmartRecruiters",
    "teamtailor": "Teamtailor",
    "unified": "Unified.to",
    "workable": "Workable",
    "calcom": "Cal.com",
    "calendly": "Calendly",
    "zoom": "Zoom",
    "webex": "Webex",
    "google": "Google Calendar",
    "meet": "Google Meet",
    "microsoft": "Microsoft 365",
    "teams": "Microsoft Teams",
}


def variables(names):
    return [{"name": name, "present": configured(name)} for name in names]


def operation(task, name, where, groups=(), *, optional=(), state=None):
    choices = [variables(keys) for keys in groups]
    if state is None:
        state = (
            "configured"
            if any(all(flag["present"] for flag in group) for group in choices)
            else "needs_setup"
        )
    return {
        "task": task,
        "name": name,
        "where": where,
        "state": state,
        "alternatives": choices,
        "optional": variables(optional),
    }


def card(key, name, operations):
    return {"id": key, "name": name, "operations": operations}


def calendar_and_meetings():
    providers = []
    for key in oauth_tokens.TOKEN:
        prefix = oauth_tokens.GROUP[key]
        groups = [(oauth_tokens.TOKEN[key],), (prefix + "_CLIENT_ID", prefix + "_REFRESH_TOKEN")]
        optional = [prefix + "_CLIENT_SECRET"] + (["MS_GRAPH_TENANT"] if prefix == "MS_GRAPH" else [])
        if key in ("google", "microsoft"):
            ops = [
                operation(
                    "Calendar", "Read upcoming events", "Connections · Calendar", groups, optional=optional
                )
            ]
        else:
            ops = [
                operation(
                    "Meeting files",
                    "Find meetings and import transcripts",
                    "Interview · Capture audio · Meeting recordings",
                    groups,
                    optional=optional,
                )
            ]
            if key == "teams":
                ops.append(recording_transcription(groups, optional))
        providers.append(card(key, NAMES[key], ops))
    for key, token_key in booking_sources.KEYS.items():
        groups = [(token_key,)]
        ops = [
            operation(
                "Calendar",
                "Read upcoming bookings" if key in ("calcom", "calendly") else "Read upcoming meetings",
                "Connections · Calendar",
                groups,
            )
        ]
        if key in ("zoom", "webex"):
            ops += [
                operation(
                    "Meeting files",
                    "List recordings and import transcripts",
                    "Interview · Capture audio · Meeting recordings",
                    groups,
                ),
                recording_transcription(groups),
            ]
        providers.append(card(key, NAMES[key], ops))
    providers.append(
        card(
            "imap",
            "IMAP mailbox",
            [
                operation(
                    "Calendar",
                    "Read calendar invitations",
                    "Connections · Calendar",
                    [mailbox.SETTINGS],
                    optional=["IMAP_FOLDER", "IMAP_PORT"],
                )
            ],
        )
    )
    return providers


def recording_transcription(groups, optional=()):
    return operation(
        "Transcription",
        "Transcribe a selected recording",
        "Interview · Capture audio · Meeting recordings",
        [(*keys, "DEEPGRAM_API_KEY") for keys in groups],
        optional=optional,
    )


def account_operations():
    embedded = access.embedded_enabled() and access.account_enabled()
    remote = access.account_enabled() and not embedded
    owner = configured("INTERVIEWCHECK_OPERATOR_EMAIL")
    embedded_keys = ("INTERVIEWCHECK_ACCESS_MODE", "INTERVIEWCHECK_OPERATOR_EMAIL")
    remote_keys = ("INTERVIEWCHECK_ACCESS_URL", "INTERVIEWCHECK_OPERATOR_EMAIL")
    signup = [
        "INTERVIEWCHECK_SIGNUP_SECRET",
        "ADMIN_EMAILS",
        "ADMIN_BOOTSTRAP_SECRET",
        "TRIAL_DAYS",
        "SESSION_TTL_DAYS",
        "OFFLINE_GRACE_DAYS",
        "PAST_DUE_GRACE_DAYS",
    ]
    accounts = card(
        "accounts",
        "InterviewCheck accounts",
        [
            operation(
                "Accounts",
                "Use embedded accounts",
                "Account · Sign in",
                [embedded_keys],
                optional=signup,
                state="configured" if embedded and owner else "needs_setup",
            ),
            operation(
                "Accounts",
                "Use a remote compatible account service",
                "Account · Sign in",
                [remote_keys],
                optional=["INTERVIEWCHECK_ACCESS_MODE"],
                state="configured" if remote and owner else "needs_setup",
            ),
        ],
    )
    stripe = []
    for plan in ("monthly", "annual"):
        keys = (*embedded_keys, "STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "STRIPE_PRICE_" + plan.upper())
        if remote and owner:
            stripe.append(
                operation(
                    "Billing", f"Open {plan} checkout", "Account · Checkout", [remote_keys], state="remote"
                )
            )
        else:
            ready = (
                embedded
                and owner
                and plan in account_stripe.plans()
                and all(configured(k) for k in keys[2:4])
            )
            stripe.append(
                operation(
                    "Billing",
                    f"Open {plan} checkout",
                    "Account · Checkout",
                    [keys],
                    optional=["PUBLIC_BASE_URL"],
                    state="configured" if ready else "needs_setup",
                )
            )
    portal_keys = [
        (*embedded_keys, "STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "STRIPE_PRICE_" + plan)
        for plan in ("MONTHLY", "ANNUAL")
    ]
    state = (
        "remote"
        if remote and owner
        else "configured"
        if any(op["state"] == "configured" for op in stripe)
        else "needs_setup"
    )
    stripe.append(
        operation(
            "Billing",
            "Open billing portal",
            "Account · Billing portal",
            [remote_keys] if state == "remote" else portal_keys,
            state=state,
        )
    )
    return [accounts, card("stripe", "Stripe", stripe)]


@router.get("/catalog")
def catalog():
    result = [
        card(
            "files",
            "Local files",
            [
                operation("Calendar", "Import iCalendar events", "Connections · Calendar", state="local"),
                operation(
                    "Candidate lookup",
                    "Import candidates from CSV",
                    "Connections · Applicant tracking",
                    state="local",
                ),
                operation(
                    "Meeting files",
                    "Import a WebVTT transcript",
                    "Interview · Import transcript exchanges",
                    state="local",
                ),
            ],
        ),
        card(
            "deepgram",
            "Deepgram",
            [
                operation(
                    "Transcription",
                    "Transcribe a call or microphone",
                    "Interview · Capture audio",
                    [("DEEPGRAM_API_KEY",)],
                ),
                operation(
                    "Transcription",
                    "Transcribe an audio or video file",
                    "Interview · Capture audio",
                    [("DEEPGRAM_API_KEY",)],
                ),
            ],
        ),
    ]
    for name, keys in authoring.MODEL_KEYS.items():
        result.append(
            card(
                name.lower().replace(" ", "_"),
                name,
                [
                    operation(
                        "References", "Generate reference answers", "Interview · Add an exchange", [keys]
                    ),
                    operation(
                        "Question planning", "Draft planned questions", "Role library · Edit role", [keys]
                    ),
                ],
            )
        )
    result.extend(calendar_and_meetings())
    for key, required in ats.KEYS.items():
        regions = {
            "teamtailor": ["TEAMTAILOR_REGION"],
            "kombo": ["KOMBO_REGION"],
            "unified": ["UNIFIED_REGION"],
        }
        ops = [
            operation(
                "Candidate lookup",
                "Find a candidate by email",
                "Connections · Applicant tracking",
                [required],
                optional=regions.get(key, []),
            )
        ]
        if key in ats_notes.NOTE_KEYS:
            ops.append(
                operation(
                    "Private notes",
                    "Send a reviewed private note",
                    "Interview · Send a private ATS note",
                    [(*required, *ats_notes.NOTE_KEYS[key])],
                )
            )
        result.append(card(key, NAMES[key], ops))
    return {"providers": result + account_operations()}
