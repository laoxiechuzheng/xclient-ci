# DIRECT bridge TLS fixtures

These synthetic certificates and the matching key are intentionally public test data. They have never identified a production service and must not be used outside tests. `test-cert.pem` identifies only localhost, so replacing the original TLS hostname with the bridge's IPv4 address would fail validation. `test-wrong-host-cert.pem` uses the same test key but a different hostname.

The opt-in Dart/Go component test explicitly trusts these fixtures only inside its test process. Product certificate verification remains strict. Tests never use a bad-certificate acceptance callback.
