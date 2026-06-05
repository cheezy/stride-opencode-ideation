# Notifications system

*Date: 2026-05-12 12:01*
*Session: 2026-05-12T120100-notifications-system*

## Problem
Time-sensitive events in the app — approval requests, board mentions, dependency completion — surface only via the UI. Users who are not actively looking at the app miss them and the system feels asynchronous in a frustrating way. Approval lag p50 currently sits around 28 hours; mention reply lag is unmeasured but anecdotally measured in days.

## Goal
Users receive timely, low-noise notifications for the small set of events that genuinely need their attention (approvals owed to them, mentions of them in comments, dependency unblocked for tasks they own), via channels they explicitly opt into (email by default, with future extensibility to in-app inbox and digest), with per-user preferences that respect Do Not Disturb windows.

## Success metrics
- Approval lag p50 drops below 8 hours within 4 weeks of launch (measured from current 28h baseline)
- Less than 5 percent of notifications marked as "not useful" by users via the per-message feedback link
- Per-user notification volume below 12 per business day on average (the noise ceiling we committed to)
- Unsubscribe / opt-out rate below 10 percent in the 60 days after launch

## Assumptions
- The existing Swoosh + SMTP mailer in `lib/kanban/mailer.ex` is the right transport for v1; we will not add a third-party notification service
- Users will configure their preferences once on initial opt-in and rarely change them
- The three event classes (approvals, mentions, dependency-unblocked) cover 90 percent of "I missed something important" complaints
- Email deliverability to corporate inboxes is already adequate (Postmark/Mailgun parity not required)

## Constraints
- Must not introduce a new background-job library — reuse the existing Oban setup
- Must not bypass the existing audit-log infrastructure — every notification dispatch is logged
- Must not send any email to a user who has not explicitly opted in to that channel
- Per-message footer with one-click unsubscribe is non-negotiable (CAN-SPAM / GDPR)

## Non-goals
- In-app notification inbox UI — defer to a v2 if usage warrants; v1 is email only
- Digest emails ("here's everything from the last 24h") — separate initiative; v1 is per-event
- Mobile push notifications — explicitly out, no native app yet
- Slack / Teams integration — explicitly out, owner-by-owner decision down the line
- Real-time browser push (Web Push API) — explicitly out, the UI already covers in-session

## Outcome
Users who are not actively in the app know when something time-sensitive needs them, without the app feeling spammy. Approval lag drops measurably. The notification preferences UI is the canonical source of truth for who-gets-what — no implicit "we'll email you because you're an admin" surprises.

## Sketch
This initiative naturally splits into three orthogonal seams that can ship independently:

1. **Event detection and queue** — emit a `notification_requested` event from each of the three event sources (approval lifecycle, comment-mention scanning, dependency-unblock hook). Land them on an Oban queue keyed by recipient + event class so a recipient never gets the same event twice.

2. **User preferences UI** — `lib/kanban_web/live/notifications/preferences_live.ex` (new). Per-event-class opt-in toggles, per-user DND window, email-address override (defaults to account email). Schema migration adds `user_notification_preferences` table.

3. **Email rendering and dispatch** — `lib/kanban/notifications/email_renderer.ex` (new). Three event-class templates that render to a shared shell (header / footer / unsubscribe link). Worker pulls from the Oban queue, checks preferences + DND window, dispatches via the existing mailer.

The seams are deliberately independent so /decompose can split this into separate Stride goals if size demands.

## Open questions
- DND window timezone source: account-level setting vs. inferred from email-domain TLD? Lean account-level explicit; revisit if too many users skip it.
- Should mention scanning be at comment-create time or batched? Batched is cheaper but introduces lag; ship comment-create-time and revisit.
- Notification template — plain text or full HTML? Lean text-first with a minimal HTML shell; revisit if users ask for richer rendering.
