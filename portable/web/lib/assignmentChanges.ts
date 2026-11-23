/** A local browser hint contains no assignment or identity data. The API remains authoritative. */
const CHANNEL = "interviewcheck-assignment-changes"
let receiver: BroadcastChannel | undefined
let listeners = 0

export function onAssignmentChange(notify: () => void) {
  try {
    const channel = receiver ??= new BroadcastChannel(CHANNEL)
    const receive = (event: MessageEvent) => { if (event.data === null) notify() }
    channel.addEventListener("message", receive)
    listeners += 1
    return () => {
      channel.removeEventListener("message", receive)
      if (--listeners === 0) { channel.close(); receiver = undefined }
    }
  } catch {
    return () => {} // Visibility changes and the deadline timer also refresh the queue.
  }
}

export function announceAssignmentChange() {
  try {
    // The publishing channel does not echo its own bulk write back to this page.
    const channel = receiver ?? new BroadcastChannel(CHANNEL)
    try { channel.postMessage(null) } finally { if (!receiver) channel.close() }
  } catch { /* Channel access can be restricted. A completed write still succeeds. */ }
}
