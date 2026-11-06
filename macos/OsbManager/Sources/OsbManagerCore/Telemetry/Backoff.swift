import Foundation

public enum Backoff {
    public static func next(failures: Int, random: Double) -> Duration {
        let exponent = min(max(failures, 1), 20)
        let ceiling = min(TelemetryLimits.backoffCapSeconds, TelemetryLimits.backoffBaseSeconds * Double(1 << exponent))
        let wait = ceiling * clamp(random)
        return .seconds(max(wait, 60))
    }

    public static func retryAfter(_ header: TimeInterval?, random: Double, failures: Int) -> Duration {
        guard let header else { return next(failures: failures, random: random) }
        return clamped(.seconds(header))
    }

    public static func clamped(_ wait: Duration) -> Duration {
        min(max(wait, TelemetryLimits.minWait), TelemetryLimits.maxWait)
    }

    public static func jitter(_ interval: Duration, random: Double) -> Duration {
        .seconds(interval.seconds * (0.9 + 0.2 * clamp(random)))
    }

    public static func startDelay(random: Double) -> Duration {
        let span = TelemetryLimits.startDelayMaxSeconds - TelemetryLimits.startDelayMinSeconds
        return .seconds(TelemetryLimits.startDelayMinSeconds + span * clamp(random))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
