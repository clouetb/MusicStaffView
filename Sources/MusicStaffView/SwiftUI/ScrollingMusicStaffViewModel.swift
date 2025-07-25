//
//  ScrollingMusicStaffViewModel.swift
//  MusicStaffView – Scrolling extension
//
//  Drives time-keeping, culls off-screen notes and exposes reactive state to
//  SwiftUI. The whole type is isolated to the **main actor** because it relies
//  on UIKit classes (`CADisplayLink`, `UIScreen`) and updates `@Published`
//  properties that directly feed SwiftUI views.
//
//  Updated 28 Jul 2025
//  - `pxPerBeat` is injected from SwiftUI through `updatePixelsPerBeat(pixels:)`
//    so BPM changes always impact speed.
//  - `payingNote` is now the note whose **head has just crossed** (or is exactly
//    under) the *real* red playhead X position (`playheadX`).
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
    /// `startBeat` is the logical beat position (relative to `currentBeat`) at which
    /// the note head reaches the leading inset (x == `leadingInset`).
    struct ScrollingNote: Identifiable, Sendable {
        let id = UUID()
        let note: MusicNote
        let duration: NoteDuration
        let startBeat: Double
    }

    // MARK: - Published state consumed by SwiftUI -----------------------------

    /// Tempo in quarter-notes per minute. Mutating this immediately changes scroll speed.
    @Published var bpm: Double

    /// Notes that are still visible or about to enter from the right.
    @Published private(set) var notes: [ScrollingNote] = []

    /// The note whose **head has most recently crossed the red playhead**.
    @Published private(set) var payingNote: MusicNote?

    // MARK: - Immutable configuration ----------------------------------------

    /// Clef used to compute vertical positions outside of UIKit drawing.
    let clef: MusicClef

    /// Strategy that converts musical spacing to pixels (px per beat).
    private let spacingStrategy: NoteSpacingStrategy

    /// Extra horizontal space, expressed in beats, inserted between successive notes.
    private let beatGapBetweenNotes: Double

    /// How far from the left edge a head must be before it is considered "entered".
    /// (1 beat worth of pixels so the glyph fully disappears before removal.)
    private let leadingInset: CGFloat

    // MARK: - Runtime mutable (not published) --------------------------------

    /// Pixels representing one beat (¼-note). Injected from SwiftUI so we can
    /// decouple visual speed from the internal spacing strategy.
    private var pxPerBeat: CGFloat

    /// Virtual timeline cursor (in beats).
    private var currentBeat: Double = 0

    /// Current visible width (provided by the SwiftUI view through `updateCanvasWidth`).
    private var canvasWidth: CGFloat = 0

    /// Current absolute X position of the red playhead (provided by SwiftUI view).
    private var playheadX: CGFloat = .nan

    /// Optional tolerance (in px) so you can trigger *slightly before* the head visually touches the playhead.
    private let headHitTolerancePx: CGFloat = 30

    // MARK: - CADisplayLink ---------------------------------------------------

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    // MARK: - Init ------------------------------------------------------------

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

        // Give pxPerBeat a sane default; SwiftUI will override it.
        let staffSpaceHeight = UIScreen.main.scale * 4
        self.pxPerBeat       = spacing.pixels(for: staffSpaceHeight, preferred: nil)

        self.leadingInset    = pxPerBeat

        enqueue(initialNotes)
    }

    // MARK: - Public API ------------------------------------------------------

    /// Inject the visual speed (in px per beat) from the SwiftUI layer.
    func updatePixelsPerBeat(pixels: CGFloat) {
        self.pxPerBeat = max(1, pixels)
        // recompute paying note with the new mapping
        recomputePayingNote()
    }

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

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    /// Enqueue one or more notes to the right of the last scheduled one.
    func enqueue(_ inputs: [ScrollingNoteInput]) {
        guard !inputs.isEmpty else { return }

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

    func updateCanvasWidth(_ width: CGFloat) {
        canvasWidth = width
    }

    /// Called by the SwiftUI view whenever the playhead absolute X changes.
    func updatePlayheadX(_ x: CGFloat) {
        playheadX = x
        recomputePayingNote()
    }

    /// Converts a note’s logical timeline (in beats) into an on-screen X offset (points).
    func xPosition(for note: ScrollingNote) -> CGFloat {
        leadingInset + CGFloat(note.startBeat - currentBeat) * pxPerBeat
    }

    // MARK: - CADisplayLink tick ---------------------------------------------

    @objc
    private func step(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let last = lastTimestamp else { return }   // first frame
        let dt = link.timestamp - last
        advance(by: dt)
    }

    private func advance(by deltaSeconds: CFTimeInterval) {
        // 1) Advance the cursor in beats.
        currentBeat += deltaSeconds * (bpm / 60.0)

        // 2) Recycle notes whose *right-edge* is left of the viewport.
        while let first = notes.first,
              xPosition(for: first) + pxPerBeat < 0 {
            notes.removeFirst()
        }

        // 3) Update the “note under playhead”.
        recomputePayingNote()
    }

    // MARK: - Paying note computation ----------------------------------------

    /// Recomputes which note should be reported as `payingNote`.
    ///
    /// Definition: the **latest** note whose **head** is at or to the *left* of
    /// the playhead (within an optional tolerance). If no head has crossed yet,
    /// we optionally fall back to the next upcoming note (or nil).
    private func recomputePayingNote() {
        guard playheadX.isFinite else {
            payingNote = nil
            return
        }

        var newestCrossed: ScrollingNote?
        var newestHeadX: CGFloat = -.infinity

        for n in notes {
            let headX = xPosition(for: n)
            if headX <= playheadX + headHitTolerancePx, headX > newestHeadX {
                newestHeadX = headX
                newestCrossed = n
            }
        }

        if let n = newestCrossed {
            payingNote = n.note
            return
        }

        // No head crossed yet: return the next upcoming one (closest on the right),
        // or nil if there are no notes.
        if let upcoming = notes
            .filter({ xPosition(for: $0) > playheadX })
            .min(by: { xPosition(for: $0) < xPosition(for: $1) }) {
            payingNote = upcoming.note
        } else {
            payingNote = nil
        }
    }
}
