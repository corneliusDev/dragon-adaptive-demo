//  GradeModel.swift
//  How much a slope changes running pace. Kept to ONE function so a better
//  model can be swapped in without touching the estimator.
//
//  Model: the linear running rule of thumb — each 1% of uphill grade costs
//  about 2% of pace, and each 1% downhill gives back about 1.2%, with the
//  benefit capped at 15% (past roughly −12% you brake instead of gaining).
//  Coaching rules of thumb put the uphill cost at roughly 1.5–3% per 1%;
//  metabolic-cost curves such as Minetti et al. (2002) are steeper, but
//  they measure energy, not pace.
//  The synthetic runner slows by the same shape (its own copy, so swapping
//  this model doesn't change the simulated world), so replays test the
//  estimator rather than a model mismatch.

import Foundation

public enum GradeModel {
    /// Pace multiplier for running a grade (rise / run, 0.05 = 5% uphill)
    /// at the same effort: > 1 is slower than on the flat.
    public static func paceFactor(grade: Double) -> Double {
        grade > 0 ? 1 + 2.0 * grade : max(0.85, 1 + 1.2 * grade)
    }
}
