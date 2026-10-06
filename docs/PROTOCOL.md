# v2 wire protocol — HarmonyOS phone ↔ bridge

The phone connects to the paired computer gateway. This is the protocol
implemented by the HarmonyOS client.

- Local: `ws://<host>:7691/v2/app`
- Public: `wss://<harmony-gateway-host>/v2/app` (TLS required; no public `ws://` fallback)

Handshake credential:

- `X-Hermes-App-Password: <password>` or `?password=<password>` (required;
  the query form is used by the HarmonyOS client because some mobile WebSocket
  stacks drop custom headers)
- `CF-Access-Client-Id` / `CF-Access-Client-Secret` (when enabled by the deployment;
  Cloudflare Access consumes them at the edge; the bridge only logs that they were present)

Text frames are JSON. Binary frames are PCM16LE mono.

## Phone → bridge

```
{"t":"hello","app":"0.1.0","proto":2,"dev":"<stable device id>"}
{"t":"sub","session":"<sid>","last_seen":123}
{"t":"dispatch","session":"<sid>","text":"...","request_id":"optional client correlation id"}
{"t":"interrupt","session":"<sid>","request_id":"cancel request id","task_request_id":"dispatch request id"}
{"t":"approve","session":"<sid>","request_id":"...","choice":"once|session|always|deny","harmony_server_request_id":"optional modern Hermes request ID"}
{"t":"clarify","session":"<sid>","request_id":"...","answer":...,"harmony_server_request_id":"optional modern Hermes request ID"}
{"t":"sessions"}
{"t":"new_session","title":"...","request_id":"optional client correlation id"}
{"t":"session_archive","session":"<sid>","archived":true,"request_id":"optional client correlation id"}
{"t":"session_archive","session":"<sid>","archived":false,"request_id":"optional client correlation id"}
{"t":"session_delete","session":"<sid>","request_id":"optional client correlation id"}
{"t":"asr_start","sr":16000}
{"t":"asr_start","sr":16000,"session":"<sid>"}   // optional session pin
binary: PCM16LE mono
{"t":"asr_end"}
{"t":"asr_cancel"}  // discard the open capture; do not attach or submit
{"t":"tts","text":"..."}
{"t":"pong"}
```

`approve.choice` is mandatory. The bridge will not invent `deny` (or any other
default). Hermes' own `approval.respond` defaults omitted choice to `deny`;
that default is never applied by us. With `harmony_server_request_id`, the bridge
answers that modern JSON-RPC request; otherwise it uses legacy
`approval.respond` / `clarify.respond` RPCs.

Session archive, restore, and delete actions may include a client `request_id`.
The bridge echoes it on the success or error response so the app can match the
result to the pending action. Clients and older bridges may omit or ignore it.

## Bridge → phone

```
{"t":"ready","epoch":"<replay_epoch>","hermes":true,"features":["a2a_task_correlation_v1","a2a_control_handoff_v1"]}
{"t":"session_resolved","request_id":"...","requested":"<stored sid>","session":"<runtime sid>"}
{"t":"interrupt_result","request_id":"...","task_request_id":"...","status":"interrupted|inactive|failed"}
{"t":"ev","p":{ ...Hermes event params, including type/session_id/payload/seq... }}
{"t":"replay","session":"<sid>","truncated":false,"latest_seq":456}
{"t":"replay","session":"<sid>","truncated":true,"latest_seq":456,"resume":{...session.resume result...}}
{"t":"sessions","list":[...],"created":"<runtime sid>","stored":"<stored sid>","request_id":"echoed when supplied"}
{"t":"sessions","list":[...],"archived_list":[...]}
{"t":"session_action","action":"archive|restore|delete","session":"<sid>","stored":"<stored sid>","archived":true,"ok":true,"request_id":"echoed when supplied"}
{"t":"transcript","body":""}  // direct voice-note path stays a voice bar
{"t":"tts_start","sr":16000,"fmt":"pcm16"}
{"t":"tts_start","sr":16000,"fmt":"pcm16","bytes":1234}  // bytes present on POST fallback
binary: PCM16LE mono
{"t":"tts_end","aborted":false,"bytes":1234}
{"t":"error","msg":"...","code":"...","request_id":"echoed for correlated actions when supplied"}
{"t":"ping","hermes":true,"epoch":"<replay_epoch>"}
```

`t:"ev"` `p` is the Hermes event params object, or a normalized card for a
server→client JSON-RPC request. Modern approval/clarify cards are delivered as
`approval.request` / `clarify.request`; their payload carries
`harmony_server_request_id` and `harmony_server_request_method`. The bridge
preserves `type` and event `seq` and may add `harmony_request_id` while a
phone-dispatched turn is active. That field correlates the event with the
dispatch that owns it. `seq` remains the resume cursor. Xiaoyi dispatch first
checks that the reserved session has no running turn or unanswered server
request, takes a sequence watermark, and requires Hermes to accept the prompt as
an immediate streaming turn with a persisted user-row ID. Completion events
match that row ID. Legacy approval/clarification events are associated only
when their sequence follows the new `message.start`. Modern server requests
have no event sequence, so their position after `message.start` in the ordered
Hermes WebSocket stream fences them to the active turn. Their server request IDs
preserve that association across reconnects and bridge restarts.
Those events produce progress while Xiaoyi keeps waiting for the explicit
decision in Harmes; the bridge never approves automatically.
After each `gateway.ready`, the computer connector advertises
`client.capabilities {server_requests:true}` and answers modern approvals and
single-question clarifications using their original JSON-RPC IDs. `request.cancel`
is forwarded to clear only the matching card. Batch clarification and server
request methods without a phone interaction are rejected promptly with
JSON-RPC `-32601`.

`new_session` replies with `t:"sessions"` and sets `created` to the runtime
session id and `stored` to the durable id. Xiaoyi persists `stored`, then uses
`session_resolved` to learn the current runtime id before matching events.
Dispatch turns are serialized per Hermes session; a concurrent prompt receives
`code:"busy"`. Xiaoyi cancellation is confirmed only after the bridge receives
Hermes' interrupt response. `request_id` is echoed on create/dispatch errors and
phone-dispatched events. `a2a_task_correlation_v1` advertises these semantics;
`a2a_control_handoff_v1` additionally guarantees Xiaoyi task events are fenced
to a fresh accepted turn, with approval and clarification cards reported as
progress while the task waits for the user to act in Harmes. Older
bridges are rejected for Xiaoyi tasks instead of silently misrouting a reply or
reporting an unconfirmed cancellation as complete.

The bridge renews its phone-turn idle deadline whenever it receives an event for
that turn. Defaults are ten minutes without an event and a one-hour maximum
duration. A timeout always reaches the phone, even if Hermes does not confirm the
interrupt; the error includes `interrupted:true` only after Hermes confirms it.

The archive list and mutations use Hermes' authenticated sessions API on the
computer. Archiving can be reversed; deletion permanently removes the session
record and is sent only after explicit confirmation on the phone.

## Resume (the path that must not be wrong)

1. Connect → bridge sends `ready` with the current Hermes `replay_epoch`.
2. Phone compares against the locally stored epoch. **If it differs, set every
   session's `last_seen` to 0.** Hermes restarts reset `seq` to 1; keeping a
   high watermark against a new epoch silently drops everything.
3. Phone sends `sub{session,last_seen}` for each session it cares about.
4. Bridge calls `session.events.since`. Each returned event (already a bare
   `params` dict) and unanswered `open_requests` entries are forwarded as
   `t:"ev"`. Then `t:"replay"`.
5. If `truncated:true`: bridge **does not** forward the partial ring. It calls
   `session.resume`, puts the result on `replay.resume`, and sets
   `truncated:true`. The phone rebuilds that session's timeline from `resume`
   (messages, legacy `pending_approval` / `pending_clarify`, `inflight`); the
   bridge rehydrates modern `open_requests` as card events after the snapshot.

Phone EventStore must treat `seq` as identity: ignore duplicates, keep
`last_seen = max(seq)`. Live events can race the replay RPC.
The bridge buffers live events for a subscribing session until its replay frame
has been sent, then forwards only events newer than the snapshot. A phone sends
`pong` for every `ping`; the bridge closes a socket after three missed heartbeat
intervals. A `ping` also reports whether Hermes is available, so the phone can
restore its active session when Hermes recovers without reconnecting the phone.
The bridge does not time out unread pongs while handling a long voice request.

### Foreground socket validation (App 0.6.5)

The phone keeps an existing socket when its UI backgrounds. Idle background
pauses the client liveness/reconnect timers; active turns still request a
HarmonyOS continuous task. The OS may suspend or close either connection.

On foreground return, the phone repeats `hello` on a retained socket and waits
for `ready` before allowing user actions. Existing connectors accept repeated
hello on the same socket. A successful acknowledgement retains the socket and
replays the current conversation from its last cursor; no prompt or decision
is resent. If ready does not arrive within 1500 ms, the phone replaces the
socket and connects normally. A quick recovery shows neutral synchronization
state; after a bounded 4000 ms grace period it exposes unresolved connection
failure. Explicit user disconnect cancels recovery and prevents auto reconnect.

## Audio

Uplink is whole-utterance PCM16LE. On `asr_end`, the bridge wraps it as WAV,
calls Hermes `file.attach`, and submits Hermes' native hidden voice-note
prompt containing the returned `@file:` reference. The bridge also obtains a
bounded private ASR hint and includes it only inside that hidden prompt, so the
agent can answer without a long transcription tool cycle. It never submits the
transcript as a visible user turn. The phone receives an empty transcript and
keeps a voice bubble. If private ASR fails, the attached WAV remains the source
of truth and the agent can inspect it. `asr_cancel` drops the buffered utterance.

After a phone text or voice turn, `message.complete` arms automatic downlink
speech. The bridge prefers `WS /api/audio/speak-stream` (raw PCM relay, no
ADPCM). `{type:"fallback"}`, an empty stream, or a stream error falls back to
`POST /api/audio/speak`, decoded/resampled to supported mono PCM16. The app
must not send a second `tts` request for the same reply.

## Auth layers

1. Cloudflare Access Service Auth (edge)
2. Bridge app password (timing-safe comparison)
3. Hermes session token, held only by the bridge on loopback


## Voice readiness (App 0.6.2 / connector 0.3.7)

The authenticated `ready.features` includes `voice_readiness_v1`. The text
handshake is immediate; a separate `voice_capabilities` frame follows:

```json
{"t":"voice_capabilities","voice":{"ready":false,"stt":false,"tts":false,"ffmpeg":true,"reason":"电脑尚未完成：语音识别、语音合成。"}}
```

The bridge reads enabled toolsets and active-provider status from Hermes'
profile-scoped APIs. If the selected provider is a custom command omitted by
Hermes' provider matrix, it reads the local profile config and accepts a
non-empty command declaration with optional `type: command`. It also verifies
an executable FFmpeg is available (including Homebrew's LaunchAgent paths).
It forwards only booleans and a fixed, safe explanation; no keys, commands or
provider configuration are sent to the phone. Missing/old APIs fail closed.
The same configured Hermes profile is used for checks, transcription and speech.

Phone requests `{"t":"voice_check"}` to refresh. The app renews checks after
60 seconds and locks voice if the result is older than 90 seconds. Disconnect,
Hermes unavailability or re-pairing also locks it. Voice input and auto playback
start disabled on a fresh install; persisted preferences never authorize voice
without a live capability report. Old bridges keep text usable but cannot
unlock voice.

`hello.voice_reply=false` opts the new app out of automatic synthesis until
readiness and user preference are known. `{"t":"voice_preferences","voice_reply":true}`
updates that preference on the connection. Omitting it preserves legacy clients'
auto-reply preference, subject to the same server readiness requirement.

The bridge rechecks at recording start, recording submission and speech
synthesis; failure emits `error.code=voice_unavailable`, rejects audio and
keeps text usable. A stale or modified phone cannot bypass the computer check.
Readiness does not execute custom commands or verify their executable paths,
dependencies, credentials, network access, quota, downloaded-model completeness
or a successful real conversation.
