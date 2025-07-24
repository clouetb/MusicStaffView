//
//  Modifiers.swift
//  MusicStaffView
//
//  Rendez les modifiers publics pour éviter les erreurs “inaccessible due to ‘internal’”.
//

import SwiftUI

// MARK: - Defaults

public enum MusicStaffViewDefaults {
    public static let maxLedgerLines: Int = 0
    public static let spaceWidth: CGFloat = 8
    public static let preferredHorizontalSpacing: CGFloat = 0
    public static let fitsStaffToBounds: Bool = false
}

// MARK: - Max ledger lines

private struct MusicStaffMaxLedgerLinesKey: EnvironmentKey {
    static let defaultValue: Int = MusicStaffViewDefaults.maxLedgerLines
}

public extension EnvironmentValues {
    var musicStaffMaxLedgerLines: Int {
        get { self[MusicStaffMaxLedgerLinesKey.self] }
        set { self[MusicStaffMaxLedgerLinesKey.self] = newValue }
    }
}

// MARK: - Space width

private struct MusicStaffSpaceWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = MusicStaffViewDefaults.spaceWidth
}

public extension EnvironmentValues {
    /// Largeur (en points) d’un “espace” de portée.
    var musicStaffSpaceWidth: CGFloat {
        get { self[MusicStaffSpaceWidthKey.self] }
        set { self[MusicStaffSpaceWidthKey.self] = newValue }
    }
}

public extension View {
    func staffSpaceWidth(_ value: CGFloat) -> some View {
        environment(\.musicStaffSpaceWidth, value)
    }
}

// MARK: - Preferred horizontal spacing (si tu en as besoin côté UIKit)

private struct MusicStaffPreferredHorizontalSpacingKey: EnvironmentKey {
    static let defaultValue: CGFloat = MusicStaffViewDefaults.preferredHorizontalSpacing
}

public extension EnvironmentValues {
    var musicStaffPreferredHorizontalSpacing: CGFloat {
        get { self[MusicStaffPreferredHorizontalSpacingKey.self] }
        set { self[MusicStaffPreferredHorizontalSpacingKey.self] = newValue }
    }
}

public extension View {
    func preferredHorizontalSpacing(_ value: CGFloat) -> some View {
        environment(\.musicStaffPreferredHorizontalSpacing, value)
    }
}

// MARK: - fitsStaffToBounds

private struct MusicStaffFitsToBoundsKey: EnvironmentKey {
    static let defaultValue: Bool = MusicStaffViewDefaults.fitsStaffToBounds
}

public extension EnvironmentValues {
    var musicStaffFitsToBounds: Bool {
        get { self[MusicStaffFitsToBoundsKey.self] }
        set { self[MusicStaffFitsToBoundsKey.self] = newValue }
    }
}

public extension View {
    func fitsStaffToBounds(_ value: Bool) -> some View {
        environment(\.musicStaffFitsToBounds, value)
    }
}
