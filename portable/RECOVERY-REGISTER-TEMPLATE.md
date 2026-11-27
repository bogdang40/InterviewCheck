# Private recovery register

Copy this blank template to the deployment owner's approved vault as a separate item. Complete the private copy outside the repository and outside the hosted VM. Witnesses need access to the register. Restrict access to key values separately.

Use UTC dates. Enter opaque item or ticket references only. Keep key values, configuration contents, signed URLs, database records and raw command output out of this register.

## Deployment and custody

| Field | Private entry |
| --- | --- |
| Deployment identifier | Awaiting identification |
| Deployment owner | Awaiting designation |
| Current key and configuration version references | Awaiting identification |
| Retained versions and the last backup that requires each | Awaiting inventory |

| Custodian role | Designated person or team | Acknowledgment date | Private acknowledgment reference |
| --- | --- | --- | --- |
| Primary | Awaiting designation | Awaiting acknowledgment | |
| Backup | Awaiting designation | Awaiting acknowledgment | |

Each custodian records their own acknowledgment of access to the designated vault items. Designation alone leaves acknowledgment pending. Review these entries when personnel, permissions, keys or configuration change.

## Fixture exercises

Record tests with generated data here. Include the software revision, fixture identifier, UTC date, checks exercised, omissions and outcome. Keep hosted restore observations in the section below.

| Date | Software and fixture | Checks and omissions | Result |
| --- | --- | --- | --- |
| | | | No fixture result recorded |

## Witnessed restore

Complete one record for the current backup and another for a retained backup from before rotation. Record the observations on the disposable restore. Keep prior records when a key changes, and mark the new generation as awaiting a drill.

| Observation | Current backup | Backup before rotation |
| --- | --- | --- |
| Owner identified archive and version | Awaiting selection | Awaiting selection |
| Expected snapshot digests from trusted inventory | | |
| Recovered key and configuration version references | | |
| Operator, independent witness and UTC date | | |
| InterviewCheck release used | | |
| Review and access database checks | Pending | Pending |
| Model, alert and TOTP counts verified or absent | Pending | Pending |
| Application startup and access checks | Pending | Pending |
| Checks skipped and reason | | |
| Outcome and next action | Awaiting witnessed restore | Awaiting witnessed restore |

A fixture pass establishes the behavior of the tested release with synthetic inputs. An offline snapshot check establishes the integrity and credential coverage reported for those files. Mark a restore as witnessed only after the named witness observes the stated checks. When a generation or check remains pending, retain that status in the handoff.
