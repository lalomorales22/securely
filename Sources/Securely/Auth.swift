import LocalAuthentication

enum AuthError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let m) = self { return m }; return nil }
}

/// Touch ID gate. The fingerprint template never leaves the Secure Enclave;
/// the OS only tells us "this is an enrolled finger" or not.
enum Auth {
    static func biometricsAvailable() -> String? {
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) { return nil }
        return err?.localizedDescription ?? "Touch ID is not available"
    }

    /// Fingerprint only. Falls back to the Mac password solely after Touch ID lockout.
    static func authenticate(reason: String) async throws {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        do {
            _ = try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let e as LAError where e.code == .biometryLockout {
            _ = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        }
    }
}
