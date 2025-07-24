//
//  NoteSpacingStrategy.swift
//
//  Defines how horizontal spacing between consecutive notes is computed.
//  All comments are intentionally in English, as requested.
//

import CoreGraphics

/// Describes the policy used to determine the horizontal distance between the
/// start-positions of two consecutive quarter-notes.
public enum NoteSpacingStrategy: Sendable, Equatable {
    
    /// Ask the underlying `UIMusicStaffView` (or SwiftUI wrapper) for its
    /// `preferredHorizontalSpacing`; when that value equals `0` the fallback is
    /// `staffSpaceHeight * defaultMultiplier` (≈ one note-head width plus a bit of air).
    case fromPreferredOrDefault(defaultMultiplier: CGFloat = 1.75)
    
    /// Always use the supplied pixel value, ignoring whatever the staff view prefers.
    case fixed(CGFloat)
    
    /// Returns the actual pixel distance to use.
    /// - Parameters:
    ///   - staffSpaceHeight: Distance between two staff lines in points.
    ///   - preferred: The staff view’s preferred spacing or `nil` if unknown.
    /// - Returns: Spacing in *device* points.
    public func pixels(for staffSpaceHeight: CGFloat,
                       preferred: CGFloat?) -> CGFloat {
        switch self {
        case let .fixed(px):
            return px
        case let .fromPreferredOrDefault(multiplier):
            if let p = preferred, p > 0 { return p }
            return staffSpaceHeight * multiplier
        }
    }
}
