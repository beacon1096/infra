import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// pi drops aborted assistant turns from provider requests, so the model cannot
// tell that the user interrupted it. Mirror Codex's `<turn_aborted>` marker.
const MARKER = "<turn_aborted>\nThe user interrupted the previous turn on purpose. Any running background exec tasks may still be running. If any tools/commands were aborted, they may have partially executed.\n</turn_aborted>";

export default function (pi: ExtensionAPI) {
  pi.on("context", async (event) => {
    const messages: any[] = [];
    let pending: any;
    for (const message of event.messages as any[]) {
      if (pending && message.role !== "toolResult") {
        messages.push({ role: "user", content: [{ type: "text", text: MARKER }], timestamp: pending.timestamp });
        pending = undefined;
      }
      messages.push(message);
      if (message.role === "assistant" && message.stopReason === "aborted") pending = message;
    }
    if (pending) messages.push({ role: "user", content: [{ type: "text", text: MARKER }], timestamp: pending.timestamp });
    return { messages };
  });
}
