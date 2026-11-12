# XClient push client

`XcPushClient` is owned by `XClientRuntime`. It starts only for a logged-in, registered device while the application is in the foreground. Background operation keeps the existing 900-second state poller; resume immediately reconnects and polls.

- `ApiPushTicketIssuer` uses a separate `ApiClient` and transport with a snapshot of the regular endpoint order. A ticket is bound to the endpoint that actually answered, never the endpoint pool's later current address. The ticket must be canonical base64url for 32 bytes, expire within 60 seconds, and use the fixed events path.
- Ticket results retain the regular API's authorization generation. A late result after logout, a new login or suspension is discarded; a current unauthorized response still expires the session.
- `IoPushTransport` uses `StrictHttpClientFactory`, shared with the regular API transport, for DIRECT connections, strict certificate validation and the current SPKI pin policy. It follows no redirects and sends only `Authorization: XClientPush <ticket>` on the stream request. Tickets never enter URLs or logs.
- SSE parsing supports UTF-8 fragments, CR/LF boundaries, comments and multiline data. A line is limited to 4096 code units and an event to 16384; sequence fields must be nonnegative safe integers. Only `event: seq` is consumed.
- Heartbeats reset a 45-second idle watchdog. Connections rotate after 130 seconds. Failures reconnect with exponential backoff and jitter, capped at 60 seconds; short failed connections do not reset the backoff.
- Hints trigger the existing bootstrap/state fetches, which still verify signed documents. `SequenceHintGate` compares even the first hint with verified versions and retries unresolved changes at most once per ten seconds.
- Stop and disposal cancel subscriptions, timers, the dedicated ticket request and the streaming socket. They never close the ordinary API transport or disable polling.

Focused verification: `flutter test --no-pub test/xboard/core/push_test.dart`. Platform stream behavior also requires an HTTPS integration test; fake streams alone do not prove server/proxy buffering or idle timeout behavior.
