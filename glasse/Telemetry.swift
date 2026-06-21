//
//  Telemetry.swift
//  glasse
//
//  Thin wrapper around Sentry for reliability + observability. Centralizing the
//  SDK here (instead of scattering SentrySDK calls) means the rest of the app
//  speaks one small vocabulary — capture / breadcrumb / span / tag — and the
//  whole thing CLEANLY no-ops until the Sentry SPM package is added and a DSN is
//  set in Secrets. Mirrors the Deepgram / MWDATDisplay optional-dependency
//  pattern already used in this project.
//
//  Why this app cares: glasse is an accessibility tool — a blind user can't see
//  a frozen screen and a Deaf user can't hear a failed caption — so we monitor
//  errors, time the Claude / Deepgram round-trips, and surface the *silent*
//  graceful-degradation fallbacks (Deepgram→Apple, conductor→simple parser).
//
//  Privacy: we never attach screenshots/view hierarchy (camera frames) or raw
//  transcripts — only operation names, timings, and error metadata.
//

import Foundation
#if canImport(Sentry)
import Sentry
#endif

enum TelemetryLevel {
    case info, warning, error
    #if canImport(Sentry)
    var sentry: SentryLevel {
        switch self {
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
    #endif
}

/// An opaque performance span. Finishing it is safe even when Sentry is absent.
struct TelemetrySpan {
    #if canImport(Sentry)
    private let span: Span?
    init(_ span: Span?) { self.span = span }
    func child(_ op: String, _ description: String) -> TelemetrySpan {
        TelemetrySpan(span?.startChild(operation: op, description: description))
    }
    func finish() { span?.finish() }
    func finish(error: Error) { span?.finish(status: .internalError) }
    #else
    init() {}
    func child(_ op: String, _ description: String) -> TelemetrySpan { self }
    func finish() {}
    func finish(error: Error) {}
    #endif
}

enum Telemetry {
    static var isEnabled: Bool {
        #if canImport(Sentry)
        return Secrets.sentryDSN.hasPrefix("https://")
        #else
        return false
        #endif
    }

    /// Call once at launch.
    static func start() {
        #if canImport(Sentry)
        guard Secrets.sentryDSN.hasPrefix("https://") else { return }
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
            options.tracesSampleRate = 1.0            // full performance tracing for the demo
            options.enableAutoPerformanceTracing = true
            options.attachScreenshot = false          // privacy: never upload camera frames
            options.attachViewHierarchy = false
            #if DEBUG
            options.environment = "debug"
            #endif
        }
        #endif
    }

    /// Record a handled error (e.g. a vision timeout or glasses failure) with context.
    static func capture(_ error: Error, _ context: [String: Any] = [:]) {
        #if canImport(Sentry)
        guard isEnabled else { return }
        SentrySDK.capture(error: error) { scope in
            for (k, v) in context { scope.setExtra(value: v, key: k) }
        }
        #endif
    }

    /// Record a notable non-error event (e.g. "Deepgram fell back to Apple").
    static func captureMessage(_ message: String, level: TelemetryLevel = .warning,
                               _ context: [String: Any] = [:]) {
        #if canImport(Sentry)
        guard isEnabled else { return }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level.sentry)
            for (k, v) in context { scope.setExtra(value: v, key: k) }
        }
        #endif
    }

    /// Leave a breadcrumb — timeline context attached to any later error.
    static func breadcrumb(_ message: String, category: String = "app") {
        #if canImport(Sentry)
        guard isEnabled else { return }
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    /// Tag the current scope (e.g. agent.kind = "captions", tts.engine = "deepgram").
    static func setTag(_ key: String, _ value: String) {
        #if canImport(Sentry)
        guard isEnabled else { return }
        SentrySDK.configureScope { $0.setTag(value: value, key: key) }
        #endif
    }

    /// Start a performance transaction; finish the returned span when done.
    static func startSpan(_ name: String, op: String) -> TelemetrySpan {
        #if canImport(Sentry)
        guard isEnabled else { return TelemetrySpan(nil) }
        return TelemetrySpan(SentrySDK.startTransaction(name: name, operation: op))
        #else
        return TelemetrySpan()
        #endif
    }
}
