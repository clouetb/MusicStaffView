//
//  ScrollingMusicStaffViewModel.swift
//  MusicStaffView – Scrolling extension
//
//  Drives time-keeping, prunes off-screen notes and exposes reactive state to
//  SwiftUI. The whole type is isolated to the **main actor** because it relies
//  on UIKit classes (`CADisplayLink`, `UIScreen`) and updates `@Published`
//  properties that directly feed SwiftUI views.
//
//  Updated 28 Jul 2025
//  - `pxPerBeat` is now injected from the SwiftUI layer through
//    `updatePixelsPerBeat(pixels:)`, so BPM changes always impact speed.
//  - `payingNote` is the note under the fixed red playhead.
//

import SwiftUI
import QuartzCore          // CADisplayLink
import Music               // MusicNote, MusicClef …
import UIKit               // UIScreen

@available(iOS 15.0, *)
@MainActor
final class ScrollingMusicStaffViewModel: ObservableObject {

    // MARK: - Nested types ----------------------------------------------------

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
    ///
    /// `startBeat` is the logical beat position (relative to `currentBeat`) at
    /// which the note head will be located at `leadingInset` (x == `leadingInset`).
    struct ScrollingNote: Identifiable, Sendable {
        let id = UUID()
        let note: MusicNote
        let duration: NoteDuration
        let startBeat: Double
    }

    // MARK: - Published state consumed by SwiftUI -----------------------------

    /// Tempo in quarter-notes per minute. Mutating this immediately changes the
    /// conversion from wall-clock seconds to beats.
    @Published var bpm: Double

    /// Notes that are still visible (or about to enter from the right).
    @Published private(set) var notes: [ScrollingNote] = []

    /// The note that currently lies under the fixed red playhead.
    @Published private(set) var payingNote: MusicNote?

    // MARK: - Immutable configuration ----------------------------------------

    /// Clef used for vertical positioning (if needed outside UIKit drawing).
    let clef: MusicClef

    /// Strategy that originally provided pixels per beat. We keep it for
    /// completeness, but the SwiftUI layer now injects the final pxPerBeat.
    private let spacingStrategy: NoteSpacingStrategy

    /// Leading inset (in pixels) so the note head is fully gone before `x < 0`.
    private let leadingInset: CGFloat

    /// Extra horizontal space between enqueued notes, expressed in beats.
    /// (e.g. 0.25 = an empty eighth-note between two consecutive heads).
    private let beatGapBetweenNotes: Double

    // MARK: - Runtime mutable state (not published) ---------------------------

    /// Pixels used to represent one beat (¼-note). It is **actively** injected
    /// from the SwiftUI layer so that changing BPM updates the perceived speed.
    private var pxPerBeat: CGFloat

    /// Virtual timeline cursor (in beats). This advances as frames elapse.
    private var currentBeat: Double = 0

    /// Current visible width (provided by the SwiftUI view via `updateCanvasWidth`).
    /// Not strictly required for the current logic, but kept for future culling logic.
    private var canvasWidth: CGFloat = 0

    /// Absolute X position (in points) of the red playhead, injected by SwiftUI.
    private var playheadX: CGFloat = .nan

    // MARK: - CADisplayLink ---------------------------------------------------

    /// Frame clock used to advance the virtual timeline.
    private var displayLink: CADisplayLink?

    /// Last timestamp received from the display link to compute `dt`.
    private var lastTimestamp: CFTimeInterval?

    // MARK: - Initializer -----------------------------------------------------

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - bpm: Initial tempo in quarter-notes per minute.
    ///   - clef: Clef used for vertical positioning.
    ///   - spacing: Strategy that initially defined the px/beat conversion.
    ///   - initialNotes: Optional notes to be placed immediately on the timeline.
    ///   - beatGapBetweenNotes: Additional gap (in beats) inserted between note heads.
    init(
        bpm: Double,
        clef: MusicClef,
        spacing: NoteSpacingStrategy,
        initialNotes: [ScrollingNoteInput] = [],
        beatGapBetweenNotes: Double = 0
    ) {
        self.bpm                 = bpm
        self.clef                = clef
        self.spacingStrategy     = spacing
        self.beatGapBetweenNotes = beatGapBetweenNotes

        // Provide a sane default so we can start before SwiftUI injects a real value.
        // Baseline staff space → 4 px @1×; multiplied by screen scale for density.
        let staffSpaceHeight = UIScreen.main.scale * 4
        self.pxPerBeat       = spacing.pixels(for: staffSpaceHeight, preferred: nil)

        // Use 1 beat (in pixels) as a leading inset so the head fully leaves the view
        // before being removed.
        self.leadingInset    = pxPerBeat

        // Seed the timeline queue.
        enqueue(initialNotes)
    }

    // MARK: - Public API ------------------------------------------------------

    /// Updates the **current** pixel-per-beat ratio. This is what effectively
    /// couples BPM (tempo) to on-screen scroll speed.
    ///
    /// - Important: Call this whenever BPM changes, or when you want to rescale
    ///   horizontally without touching BPM.
    func updatePixelsPerBeat(pixels: CGFloat) {
        self.pxPerBeat = max(1, pixels)  // never allow zero or negative values
    }

    /// Starts the display link (frame clock). Should be called from `onAppear`.
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

    /// Stops the display link. Should be called from `onDisappear`.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    /// Enqueues a batch of notes to the right of the last scheduled one, inserting
    /// `beatGapBetweenNotes` beats between note heads.
    func enqueue(_ inputs: [ScrollingNoteInput]) {
        guard !inputs.isEmpty else { return }

        // Determine starting beat for the first new note.
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

    /// Injects the absolute X position of the red playhead (in points). This allows
    /// the model to compute which note currently lies under it.
    func updatePlayheadX(_ x: CGFloat) {
        playheadX = x
        recomputePayingNote()
    }

    /// Converts a note’s logical timeline (beats) into an on-screen X offset (points).
    ///
    /// The left edge of the view is 0; `leadingInset` is the position where the head
    /// is considered to **enter** the viewport from the right.
    func xPosition(for note: ScrollingNote) -> CGFloat {
        leadingInset + CGFloat(note.startBeat - currentBeat) * pxPerBeat
    }

    // MARK: - CADisplayLink tick ---------------------------------------------

    /// Frame callback. Computes time delta from the last frame and advances state.
    @objc
    private func step(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }

        // First frame after `start`: we only store the timestamp.
        guard let last = lastTimestamp else { return }

        let dt = link.timestamp - last
        advance(by: dt)
    }

    /// Advances the virtual timeline, prunes off-screen notes and recomputes the
    /// note under the playhead.
    private func advance(by deltaSeconds: CFTimeInterval) {
        // Convert seconds → beats using the current tempo.
        currentBeat += deltaSeconds * (bpm / 60.0)

        // Recycle notes whose right edge is fully offscreen (left of x == 0).
        while let first = notes.first,
              xPosition(for: first) + pxPerBeat < 0 {
            notes.removeFirst()
        }

        // Update which note is currently under the red playhead.
        recomputePayingNote()
    }

    // MARK: - Paying note computation ----------------------------------------

    /// Recomputes the note that currently lies under the red playhead.
    ///
    /// The algorithm is two-stage:
    ///  1. Find a note whose horizontal extent (head → tail) covers the playhead X.
    ///  2. Fallback to the closest head if no exact hit is found (avoids flicker).
    private func recomputePayingNote() {
        guard playheadX.isFinite else {
            payingNote = nil
            return
        }

        // 1) Exact hit: the playhead lies between the head and the tail of a note.
        if let hit = notes.first(where: { n in
            let headX = xPosition(for: n)
            let tailX = headX + pxPerBeat * CGFloat(n.duration.rawValue)
            return playheadX >= headX && playheadX < tailX
        }) {
            payingNote = hit.note
            return
        }

        // 2) No exact hit → take the closest head position.
        if let closest = notes.min(by: { a, b in
            abs(xPosition(for: a) - playheadX) < abs(xPosition(for: b) - playheadX)
        }) {
            payingNote = closest.note
        } else {
            payingNote = nil
        }
    }
}
