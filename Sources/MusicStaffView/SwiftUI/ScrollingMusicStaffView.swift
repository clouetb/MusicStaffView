//
//  ScrollingMusicStaffView.swift
//  MusicStaffView – Scrolling extension
//
//  24 Jul 2025
//

import SwiftUI
import Music
import UIKit

// MARK: - Public Scrolling View

@available(iOS 15.0, *)
public struct ScrollingMusicStaffView: View {

    // ---- Public configuration kept locally so the SwiftUI View stays value-type
    private let maxLedgerLines: Int
    private let spaceWidth: CGFloat
    private let beatGapBetweenNotes: Double

    // ---- Reactive model that does the timing / scrolling
    @StateObject private var model: ScrollingMusicStaffViewModel

    // MARK: Init
    public init(
        bpm: Double,
        clef: MusicClef = .treble,
        spacingStrategy: NoteSpacingStrategy = .fromPreferredOrDefault(),
        initialNotes: [MusicNote] = [],
        maxLedgerLines: Int = 4,
        spaceWidth: CGFloat = 8,              // vertical density controller
        beatGapBetweenNotes: Double = 0.25    // horizontal gap in beats
    ) {
        let seeds = initialNotes.map {
            ScrollingMusicStaffViewModel.ScrollingNoteInput($0, duration: .quarter)
        }

        _model = StateObject(
            wrappedValue: ScrollingMusicStaffViewModel(
                bpm: bpm,
                clef: clef,
                spacing: spacingStrategy,
                initialNotes: seeds,
                beatGapBetweenNotes: beatGapBetweenNotes
            )
        )

        self.maxLedgerLines = maxLedgerLines
        self.spaceWidth = spaceWidth
        self.beatGapBetweenNotes = beatGapBetweenNotes
    }

    // MARK: Body
    public var body: some View {
        // Same height for the static staff and every note mini-view.
        let height = StaffMetrics.height(spaceWidth: spaceWidth,
                                         maxLedgerLines: maxLedgerLines)

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                // 1) Static, non-moving staff
                StaffLayer(
                    clef: model.clef,
                    maxLedgerLines: maxLedgerLines,
                    fitsToBounds: false
                )
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: .topLeading)
                .allowsHitTesting(false)

                // 2) Foreground moving notes – each note is its own tiny UIMusicStaffView
                ForEach(model.notes) { scrolling in
                    NoteView(
                        note: scrolling.note,
                        clef: model.clef,
                        maxLedgerLines: maxLedgerLines,
                        desiredHeight: height
                    )
                    .offset(x: model.xPosition(for: scrolling), y: 0)
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .onAppear {
                model.updateCanvasWidth(geo.size.width)
                model.start()
            }
            .onChange(of: geo.size) { newSize in
                model.updateCanvasWidth(newSize.width)
            }
            .onDisappear { model.stop() }
        }
        .frame(height: height) // avoids clipping of very high/low notes & clef
    }

    // MARK: - Public API passthroughs

    /// Change tempo live.
    public func setBPM(_ newBPM: Double) {
        model.bpm = newBPM
    }

    /// Queue extra notes to scroll.
    public func addNotes(_ notes: [MusicNote]) {
        let inputs = notes.map {
            ScrollingMusicStaffViewModel.ScrollingNoteInput($0, duration: .quarter)
        }
        model.enqueue(inputs)
    }

    /// Convenience access to the left-most visible note (if your VM exposes it).
    public var leftMostVisibleNote: MusicNote? {
        model.leftMostVisibleNote
    }
}

// MARK: - Staff metrics helper

@available(iOS 15.0, *)
private enum StaffMetrics {
    /// Height of a staff *including* the space reserved for the `maxLedgerLines`
    /// above and below, when `fitsStaffToBounds == false`.
    ///
    /// In `UIMusicStaffView.spaceWidth`, the formula is:
    ///   `spaceWidth = bounds.height / (6.0 + CGFloat(ledgerAbove + ledgerBelow))`
    ///
    /// If we want to *fix* `spaceWidth`, we invert it:
    ///   `bounds.height = spaceWidth * (6 + ledgerAbove + ledgerBelow)`
    ///
    /// With symmetric `maxLedgerLines` above/below:
    ///   `bounds.height = spaceWidth * (6 + 2*maxLedgerLines)`
    static func height(spaceWidth: CGFloat, maxLedgerLines: Int) -> CGFloat {
        spaceWidth * (6.0 + CGFloat(2 * maxLedgerLines))
    }
}

// MARK: - Static staff (lines + clef)

@available(iOS 15.0, *)
private struct StaffLayer: UIViewRepresentable {
    let clef: MusicClef
    let maxLedgerLines: Int
    let fitsToBounds: Bool

    func makeUIView(context: Context) -> UIMusicStaffView {
        let v = UIMusicStaffView()
        v.elementArray = [clef]
        v.maxLedgerLines = maxLedgerLines
        v.shouldDrawClef = true
        v.fitsStaffToBounds = fitsToBounds
        v.spacing = .uniformTrailingSpace
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIMusicStaffView, context: Context) {
        uiView.elementArray = [clef]
        uiView.maxLedgerLines = maxLedgerLines
        uiView.fitsStaffToBounds = fitsToBounds
        uiView.setNeedsDisplay()
    }
}

// MARK: - One note wrapper

/// One SwiftUI wrapper around a tiny `UIMusicStaffView` that draws only
/// the note (with its accidentals, stems…) on top of the main static staff.
/// The view’s *height* is forced to the global staff height so the centerline
/// matches and vertical positioning stays correct.
@available(iOS 15.0, *)
private struct NoteView: UIViewRepresentable {
    let note: MusicNote
    let clef: MusicClef
    let maxLedgerLines: Int
    let desiredHeight: CGFloat

    func makeUIView(context: Context) -> MiniNoteStaffView {
        let v = MiniNoteStaffView(
            note: note,
            clef: clef,
            desiredHeight: desiredHeight,
            maxLedgerLines: maxLedgerLines
        )
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: MiniNoteStaffView, context: Context) {
        uiView.update(note: note,
                      clef: clef,
                      desiredHeight: desiredHeight,
                      maxLedgerLines: maxLedgerLines)
    }
}

// MARK: - UIKit micro-view that leverages UIMusicStaffView to draw the note

@available(iOS 15.0, *)
private final class MiniNoteStaffView: UIMusicStaffView {

    private var desiredHeight: CGFloat = 0

    // Designated init
    init(note: MusicNote,
         clef: MusicClef,
         desiredHeight: CGFloat,
         maxLedgerLines: Int)
    {
        self.desiredHeight = desiredHeight
        super.init(frame: CGRect(origin: .zero,
                                 size: CGSize(width: 1, height: desiredHeight)))

        self.maxLedgerLines = maxLedgerLines
        self.fitsStaffToBounds = false
        self.shouldDrawClef = false                // ← no clef per-note
        self.spacing = .preferred
        self.staffColor = .clear                   // hide staff lines
        self.elementArray = [clef, note]
        self.setNeedsDisplay()
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(note: MusicNote,
                clef: MusicClef,
                desiredHeight: CGFloat,
                maxLedgerLines: Int)
    {
        self.desiredHeight = desiredHeight
        self.maxLedgerLines = maxLedgerLines
        self.elementArray = [clef, note]

        // Force the same height as the main staff so the centerline matches.
        var f = self.frame
        f.size.height = desiredHeight
        if f.size.width == 0 { f.size.width = 1 }
        self.frame = f

        self.staffColor = .clear
        self.setNeedsDisplay()
    }

    // Ensure height stays what we asked for if the system relayouts us.
    override func layoutSubviews() {
        super.layoutSubviews()
        if frame.height != desiredHeight {
            frame.size.height = desiredHeight
        }
        // Ensure staff lines stay hidden (setupLayers may reset colors)
        self.staffLayer.strokeColor = UIColor.clear.cgColor
    }
}
