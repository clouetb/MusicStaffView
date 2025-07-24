//
//  ScrollingMusicStaffViewModel.swift
//  MusicStaffView – Scrolling extension
//
//  Drives time-keeping, culls off-screen notes and exposes reactive state to
//  SwiftUI. The whole type is isolated to the **main actor** because it relies
//  on UIKit classes (`CADisplayLink`, `UIScreen`) and updates `@Published`
//  properties that directly feed SwiftUI views.
//
//  All inline documentation is written in English as requested.
//
//  Updated 23 Jul 2025 – Clean compile against Xcode 16 / Swift 6 on iOS 15.
//

import SwiftUI
import Combine
import QuartzCore          // CADisplayLink
import Music               // Provides MusicNote, MusicClef …
import UIKit               // UIScreen

// MARK: - View-model

@available(iOS 15.0, *)
@MainActor
final class ScrollingMusicStaffViewModel: ObservableObject {

    // MARK: - Nested types

    /// Musical duration expressed in beats where a quarter-note == 1 beat.
    enum NoteDuration: Double, Sendable, CaseIterable {
        case whole      = 4
        case half       = 2
        case quarter    = 1
        case eighth     = 0.5
        case sixteenth  = 0.25
    }

    /// Public input payload used by the higher-level API (`enqueue`).
    struct ScrollingNoteInput: Sendable {
        let note: MusicNote
        let duration: NoteDuration

        init(_ note: MusicNote, duration: NoteDuration = .quarter) {
            self.note     = note
            self.duration = duration
        }
    }

    /// Internal representation of a note placed on the scrolling timeline.
    /// `startBeat` is the logical beat position (relative to `currentBeat`) at which
    /// the note head reaches the leading inset (x == `leadingInset`).
    struct ScrollingNote: Identifiable, Sendable {
        let id = UUID()
        let note: MusicNote
        let duration: NoteDuration
        let startBeat: Double
    }

    // MARK: - Published state consumed by SwiftUI

    /// Tempo in quarter-notes per minute. Mutating this immediately changes scroll speed.
    @Published var bpm: Double

    /// Notes that are still visible or about to enter from the right.
    @Published private(set) var notes: [ScrollingNote] = []

    /// First note whose right edge is not completely off-screen on the left.
    @Published private(set) var leftMostVisibleNote: MusicNote?

    // MARK: - Immutable configuration

    /// Clef used to compute vertical positions outside of UIKit drawing.
    let clef: MusicClef

    /// Strategy that converts musical spacing to pixels (px per beat).
    private let spacingStrategy: NoteSpacingStrategy

    /// Number of pixels that represent one beat (¼-note).
    private let pxPerBeat: CGFloat

    /// Leading inset (in pixels) so that the note head is fully gone before x < 0.
    private let leadingInset: CGFloat

    /// Extra horizontal space, expressed in beats, inserted between successive notes.
    /// (e.g. 0.25 = one empty eighth note between two notes)
    private let beatGapBetweenNotes: Double

    // MARK: - Runtime mutable (not published)

    /// Virtual timeline cursor (in beats).
    private var currentBeat: Double = 0

    /// Current visible width (provided by the SwiftUI view through `updateCanvasWidth`).
    private var canvasWidth: CGFloat = 0

    // MARK: - CADisplayLink

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    // MARK: - Initialiser

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - bpm: Initial tempo in quarter-notes per minute.
    ///   - clef: Clef used for vertical positioning.
    ///   - spacing: Strategy responsible for converting beats to pixels.
    ///   - initialNotes: Optional starting notes to put immediately on the timeline.
    ///   - beatGapBetweenNotes: Extra gap (in beats) inserted between enqueued notes.
    init(
        bpm: Double,
        clef: MusicClef,
        spacing: NoteSpacingStrategy,
        initialNotes: [ScrollingNoteInput] = [],
        beatGapBetweenNotes: Double = 0
    ) {
        self.bpm                  = bpm
        self.clef                 = clef
        self.spacingStrategy      = spacing
        self.beatGapBetweenNotes  = beatGapBetweenNotes

        // Baseline staff space → 4 px per space @1×; multiplied by screen scale.
        // This gives a consistent visual density across devices.
        let staffSpaceHeight = UIScreen.main.scale * 4
        self.pxPerBeat       = spacing.pixels(for: staffSpaceHeight, preferred: nil)

        // Use 1 beat worth of pixels as a leading inset so the note head is fully off
        // the left side before we remove it from memory.
        self.leadingInset    = pxPerBeat

        // Seed the queue.
        enqueue(initialNotes)
    }

    // deinit must run on the main actor so accessing `displayLink` is safe.
    // (Nothing to do explicitly here right now.)

    // MARK: - Public control surface

    /// Starts the animation. Should be called from `View.onAppear`.
    func start() {
        guard displayLink == nil else { return }
        lastTimestamp = nil

        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30,
                                                        maximum: 120,
                                                        preferred: 60)
        link.add(to: .main, forMode: .default)
        displayLink = link
    }

    /// Stops the animation. Should be called from `View.onDisappear`.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    /// Enqueues a series of notes to the right of the last scheduled one, with the
    /// configured `beatGapBetweenNotes` inserted between each.
    func enqueue(_ inputs: [ScrollingNoteInput]) {
        guard !inputs.isEmpty else { return }

        // Compute where the first of the new notes should start.
        var nextStart = notes.last
            .map { $0.startBeat + $0.duration.rawValue + beatGapBetweenNotes }
            ?? currentBeat

        for input in inputs {
            notes.append(
                ScrollingNote(note: input.note,
                              duration: input.duration,
                              startBeat: nextStart)
            )
            nextStart += input.duration.rawValue + beatGapBetweenNotes
        }
    }

    /// Called by the SwiftUI view when the viewport width changes.
    func updateCanvasWidth(_ width: CGFloat) {
        canvasWidth = width
    }

    /// Converts a note’s logical timeline (in beats) into an on-screen X offset (points).
    /// The left edge of the view is 0, and `leadingInset` is the position where the head
    /// is considered to first enter the viewport.
    func xPosition(for note: ScrollingNote) -> CGFloat {
        leadingInset + CGFloat(note.startBeat - currentBeat) * pxPerBeat
    }

    // MARK: - CADisplayLink tick

    /// CADisplayLink callback. Advances the timeline by the elapsed time since last frame.
    @objc
    private func step(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }

        // First frame after `start`: just record the timestamp, do not advance yet.
        guard let last = lastTimestamp else { return }

        let dt = link.timestamp - last
        advance(by: dt)
    }

    /// Advances the virtual timeline, removes off-screen notes and publishes state to SwiftUI.
    private func advance(by deltaSeconds: CFTimeInterval) {
        // 1) Advance the cursor in beats.
        currentBeat += deltaSeconds * (bpm / 60.0)

        // 2) Drop notes whose right-edge is completely out of view on the left.
        //    We consider a note fully gone when its x + width(one beat) < 0.
        while let first = notes.first,
              xPosition(for: first) + pxPerBeat < 0 {
            notes.removeFirst()
        }

        // 3) Update the “left-most visible” helper.
        leftMostVisibleNote = notes.first(where: { xPosition(for: $0) + pxPerBeat >= 0 })?.note
    }
}
