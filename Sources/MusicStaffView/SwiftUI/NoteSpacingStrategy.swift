//
//  NoteSpacingStrategy.swift
//
//  Defines how horizontal spacing between consecutive notes is computed.
//  All comments are intentionally in English, as requested.
//

import CoreGraphics

/// Strategy describing how to compute the horizontal distance (in **points**) between
/// the start positions of two consecutive **quarter-notes** on the scrolling staff.
///
/// The value returned by `pixels(for:preferred:)` is later converted to px-per-beat
/// and finally to an on-screen X offset by the view-model.
public enum NoteSpacingStrategy: Sendable, Equatable {

    // MARK: - Cases

    /// Use the staff view’s `preferredHorizontalSpacing` when available and > 0.
    /// Otherwise, fall back to `staffSpaceHeight * defaultMultiplier`.
    ///
    /// - Parameter defaultMultiplier:
    ///   Multiplicative factor applied to `staffSpaceHeight` (the distance between two
    ///   staff **lines** in points) to obtain a sensible default note spacing when
    ///   the staff view does not provide any preferred spacing (or returns 0).
    ///
    /// Typical values are around **1.5–2.0**, which roughly equals one note-head width
    /// plus a bit of padding.
    case fromPreferredOrDefault(defaultMultiplier: CGFloat = 1.75)

    /// Always use a fixed, absolute pixel value, ignoring any staff view preference.
    case fixed(CGFloat)

    // MARK: - API

    /// Compute the horizontal spacing to use for **one quarter-note beat**.
    ///
    /// - Parameters:
    ///   - staffSpaceHeight: The distance between two staff **lines** (not spaces) in points.
    ///   - preferred: The staff view’s preferred spacing (if any). `nil` means “unknown”.
    /// - Returns: The spacing in device points.
    public func pixels(
        for staffSpaceHeight: CGFloat,
        preferred: CGFloat?
    ) -> CGFloat {
        switch self {
        case let .fixed(px):
            return px

        case let .fromPreferredOrDefault(multiplier):
            if let p = preferred, p > 0 {
                return p
            }
            return staffSpaceHeight * multiplier
        }
    }
}
