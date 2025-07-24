//
//  ScrollingMusicStaffViewModel.swift
//  MusicStaffView – Scrolling extension
//
//  Drives time‑keeping, culls off‑screen notes and exposes reactive state to
//  SwiftUI.  The whole type is isolated to the **main actor** because it relies
//  on UIKit classes (`CADisplayLink`, `UIScreen`) and updates `@Published`
//  properties that directly feed SwiftUI views.
//
//  All inline documentation is written in English as requested.
//
//  Updated 23 Jul 2025 – Clean compile against Xcode 16 / Swift 6 on iOS 15.
//

import SwiftUI
import Combine
import QuartzCore          // CADisplayLink
import Music               // Provides MusicNote, MusicClef …
import UIKit               // UIScreen

// MARK: – View‑model

@available(iOS 15.0, *)
@MainActor                                         // <-- entire class on main
final class ScrollingMusicStaffViewModel: ObservableObject {
    // MARK: Nested types
    
    /// Musical duration expressed in beats (¼‑note == 1).
    enum NoteDuration: Double, Sendable, CaseIterable {
        case whole      = 4
        case half       = 2
        case quarter    = 1
        case eighth     = 0.5
        case sixteenth  = 0.25
    }
    
    /// Input type for API users when they add notes.
    struct ScrollingNoteInput: Sendable {
        let note: MusicNote
        let duration: NoteDuration
        
        init(_ note: MusicNote, duration: NoteDuration = .quarter) {
            self.note     = note
            self.duration = duration
        }
    }
    
    /// Internal representation used during scrolling.
    struct ScrollingNote: Identifiable, Sendable {
        let id = UUID()
        let note: MusicNote
        let duration: NoteDuration
        let startBeat: Double       // timeline coordinate (beats) where head appears at x == leadingInset
    }
    
    // MARK: Published state consumed by SwiftUI
    
    /// Tempo in quarter‑notes per minute.  Mutating this instantly affects speed.
    @Published var bpm: Double
    
    /// Notes still visible or about to enter from the right.
    @Published private(set) var notes: [ScrollingNote] = []
    
    /// First note whose right‑edge is not yet fully left of the viewport.
    @Published private(set) var leftMostVisibleNote: MusicNote?
    
    // MARK: Immutable configuration
    
    let clef: MusicClef
    private let spacingStrategy: NoteSpacingStrategy
    private let pxPerBeat: CGFloat           // pixels representing one beat (¼‑note)
    private let leadingInset: CGFloat        // one note‑width so glyph fully disappears
    private let beatGapBetweenNotes: Double  // Espace ajouté entre 2 notes, exprimé en *beats* (ex: 0.25 = une croche vide).
    // MARK: Runtime mutable (not published)
    
    private var currentBeat: Double = 0      // virtual time cursor (beats)
    private var canvasWidth: CGFloat = 0     // provided by GeometryReader
    
    // MARK: CADisplayLink
    
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    
    // MARK: Initialiser
    
    init(bpm: Double,
         clef: MusicClef,
         spacing: NoteSpacingStrategy,
         initialNotes: [ScrollingNoteInput] = [],
         beatGapBetweenNotes: Double = 0
    ) {
        self.bpm             = bpm
        self.clef            = clef
        self.spacingStrategy = spacing
        self.beatGapBetweenNotes = beatGapBetweenNotes
        
        // Baseline staff space → 4 px per space @1×; multiplied by screen scale.
        let staffSpaceHeight = UIScreen.main.scale * 4
        self.pxPerBeat       = spacing.pixels(for: staffSpaceHeight, preferred: nil)
        self.leadingInset    = pxPerBeat      // ensures head fully exits before x < 0
        
        enqueue(initialNotes)
    }
    
    // deinit must run on the main actor so accessing `displayLink` is safe.
    
    
    // MARK: Public control surface
    
    /// Starts the animation; call from `View.onAppear`.
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
    
    /// Stops the animation; call from `View.onDisappear`.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }
    
    /// Adds notes to the right‑hand queue regardless of scroll position.
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
    
    /// Injected by SwiftUI whenever the viewport width changes.
    func updateCanvasWidth(_ width: CGFloat) { canvasWidth = width }
    
    /// Converts a note’s logical time into a horizontal offset.
    func xPosition(for note: ScrollingNote) -> CGFloat {
        leadingInset + CGFloat(note.startBeat - currentBeat) * pxPerBeat
    }
    
    // MARK: CADisplayLink tick
    
    @objc
    private func step(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let last = lastTimestamp else { return }   // first frame
        let dt = link.timestamp - last
        advance(by: dt)
    }
    
    /// Advances the virtual timeline, culls off‑screen notes, updates bindings.
    private func advance(by deltaSeconds: CFTimeInterval) {
        // 1️⃣ Advance cursor in beats.
        currentBeat += deltaSeconds * (bpm / 60.0)
        
        // 2️⃣ Recycle notes whose *right‑edge* is left of the viewport.
        while let first = notes.first,
              xPosition(for: first) + pxPerBeat < 0 {
            notes.removeFirst()
        }
        
        // 3️⃣ Publish left‑most visible note.
        leftMostVisibleNote = notes.first(where: { xPosition(for: $0) + pxPerBeat >= 0 })?.note
    }
}
