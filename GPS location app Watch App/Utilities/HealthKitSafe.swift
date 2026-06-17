import Foundation
import HealthKit

/// Creates an HKQuantity while guarding against NaN/Infinity values.
/// HealthKit's HKQuantity(unit:doubleValue:) throws an NSInvalidArgumentException
/// (which crashes the app) if given a non-finite value. Removing GPS speed caps
/// makes extreme/invalid derived values possible, so all quantities are routed
/// through this guard.
func HKQuantitySafe(unit: HKUnit, doubleValue: Double) -> HKQuantity {
    let safeValue = doubleValue.isFinite ? doubleValue : 0.0
    return HKQuantity(unit: unit, doubleValue: safeValue)
}

extension Double {
    /// Returns a finite value (NaN/Inf → fallback). Use for HealthKit metadata.
    func hkFinite(_ fallback: Double = 0.0) -> Double {
        isFinite ? self : fallback
    }
}

/// Sanitizes a HealthKit metadata dictionary so no non-finite Double / NSNumber
/// reaches healthStore.save (which would throw and crash).
func sanitizedHealthKitMetadata(_ metadata: [String: Any]) -> [String: Any] {
    var result = metadata
    for (key, value) in metadata {
        if let d = value as? Double {
            result[key] = d.isFinite ? d : 0.0
        } else if let f = value as? Float {
            result[key] = f.isFinite ? f : 0.0
        } else if let n = value as? NSNumber {
            let dv = n.doubleValue
            if !dv.isFinite { result[key] = 0.0 }
        }
    }
    return result
}
