//
//  ScrollingMusicStaffView.swift
//  MusicStaffView – Scrolling extension
//
//  Created: 24 Jul 2025
//
//  This SwiftUI wrapper renders:
//   1) A **fixed** staff (clef + 5 lines) that never scrolls.
//   2) A stream of **scrolling notes** (each drawn by its own tiny UIMusicStaffView)
//      that are **masked** on the left so they appear to disappear “behind” the clef.
//   3) A **fixed vertical red playhead** located a bit to the right of the clef.
//      The view-model exposes the note that currently lies under that playhead
//      through `payingNote` (name kept to match your original request).
//

import SwiftUI
import Music
import UIKit

@available(iOS 15.0, *)
public struct ScrollingMusicStaffView: View {

    // MARK: - External control (binding) --------------------------------------

    /// Externally-driven BPM. Using a `Binding` ensures the slider actually
    /// drives the underlying model in real time.
    @Binding private var bpm: Double

    // MARK: - Public configuration -------------------------------------------

    private let maxLedgerLines: Int
    private let spaceWidth: CGFloat
    private let beatGapBetweenNotes: Double
    private let visualScale: CGFloat
    private let spacingStrategy: NoteSpacingStrategy

    /// Explicit pixels-per-beat used to map beats to screen speed. This allows
    /// you to decouple *visual* speed from the spacing strategy of the staff.
    private let scrollPixelsPerBeat: CGFloat

    /// Extra horizontal padding (in *spaces*) added to the measured clef width
    /// to compute the left “curtain” that hides notes under the clef.
    private let clefPaddingInSpaces: CGFloat

    /// Distance (in *spaces*) between the curtain (mask) and the red playhead.
    private let playheadOffsetInSpaces: CGFloat

    /// Playhead visual properties.
    private let playheadWidth: CGFloat
    private let playheadColor: Color

    /// Optional callback invoked whenever the `payingNote` changes.
    private var payingNoteHandler: ((MusicNote?) -> Void)?

    // MARK: - Reactive model --------------------------------------------------

    /// The driving view-model (time-keeping, pruning, note under playhead, …).
    @StateObject private var model: ScrollingMusicStaffViewModel

    // MARK: - Runtime measurements -------------------------------------------

    /// The **right-most X** (in SwiftUI coordinates) of the drawn clef (used to
    /// position both the mask and the playhead precisely).
    @State private var clefRightEdge: CGFloat = 0

    // MARK: - Designated init (Binding BPM) ----------------------------------

    /// Designated initializer, used when the tempo is externally controlled
    /// (e.g. by a SwiftUI `Slider`) via a `Binding<Double>`.
    public init(
        bpm: Binding<Double>,
        clef: MusicClef = .treble,
        spacingStrategy: NoteSpacingStrategy = .fromPreferredOrDefault(),
        initialNotes: [MusicNote] = [],
        maxLedgerLines: Int = 4,
        spaceWidth: CGFloat = 8,
        beatGapBetweenNotes: Double = 0,
        visualScale: CGFloat = 1.2,
        scrollPixelsPerBeat: CGFloat = 120,          // Visual horizontal speed.
        clefPaddingInSpaces: CGFloat = -1,
        playheadOffsetInSpaces: CGFloat = 4,
        playheadWidth: CGFloat = 3.0,
        playheadColor: Color = .red.opacity(0.9)
    ) {
        self._bpm = bpm

        // Convert the caller's MusicNote array to the model input type.
        let seeds = initialNotes.map {
            ScrollingMusicStaffViewModel.ScrollingNoteInput($0, duration: .quarter)
        }

        // Create the model (StateObject) with initial state.
        _model = StateObject(
            wrappedValue: ScrollingMusicStaffViewModel(
                bpm: bpm.wrappedValue,
                clef: clef,
                spacing: spacingStrategy,
                initialNotes: seeds,
                beatGapBetweenNotes: beatGapBetweenNotes
            )
        )

        // Store all configuration values locally.
        self.maxLedgerLines           = maxLedgerLines
        self.spaceWidth               = spaceWidth
        self.beatGapBetweenNotes      = beatGapBetweenNotes
        self.visualScale              = visualScale
        self.spacingStrategy          = spacingStrategy
        self.scrollPixelsPerBeat      = scrollPixelsPerBeat
        self.clefPaddingInSpaces      = clefPaddingInSpaces
        self.playheadOffsetInSpaces   = playheadOffsetInSpaces
        self.playheadWidth            = playheadWidth
        self.playheadColor            = playheadColor
    }

    // MARK: - Convenience init (constant BPM) --------------------------------

    /// Convenience initializer for when the BPM is **not** driven by a `Binding`.
    /// It simply wraps the provided constant into a `.constant` binding.
    public init(
        bpm: Double,
        clef: MusicClef = .treble,
        spacingStrategy: NoteSpacingStrategy = .fromPreferredOrDefault(),
        initialNotes: [MusicNote] = [],
        maxLedgerLines: Int = 4,
        spaceWidth: CGFloat = 8,
        beatGapBetweenNotes: Double = 1.0,
        visualScale: CGFloat = 1.2,
        scrollPixelsPerBeat: CGFloat = 120,
        clefPaddingInSpaces: CGFloat = 0.0,
        playheadOffsetInSpaces: CGFloat = 1.6,
        playheadWidth: CGFloat = 3.0,
        playheadColor: Color = .red.opacity(0.9)
    ) {
        self.init(
            bpm: .constant(bpm),
            clef: clef,
            spacingStrategy: spacingStrategy,
            initialNotes: initialNotes,
            maxLedgerLines: maxLedgerLines,
            spaceWidth: spaceWidth,
            beatGapBetweenNotes: beatGapBetweenNotes,
            visualScale: visualScale,
            scrollPixelsPerBeat: scrollPixelsPerBeat,
            clefPaddingInSpaces: clefPaddingInSpaces,
            playheadOffsetInSpaces: playheadOffsetInSpaces,
            playheadWidth: playheadWidth,
            playheadColor: playheadColor
        )
    }

    // MARK: - Fluent API ------------------------------------------------------

    /// Registers a callback to be notified whenever the playing note changes.
    public func onPayingNoteChange(_ handler: @escaping (MusicNote?) -> Void) -> Self {
        var copy = self
        copy.payingNoteHandler = handler
        return copy
    }

    /// Adds more notes to the scrolling timeline.
    public func addNotes(_ notes: [MusicNote]) {
        let inputs = notes.map {
            ScrollingMusicStaffViewModel.ScrollingNoteInput($0, duration: .quarter)
        }
        model.enqueue(inputs)
    }

    /// Shortcut to the model’s current paying note.
    public var payingNote: MusicNote? {
        model.payingNote
    }

    // MARK: - View body -------------------------------------------------------

    public var body: some View {
        // Effective (scaled) space width. This is a visual zoom of the staff.
        let scaledSpaceWidth = spaceWidth * visualScale

        // View height based on space width and the number of ledger lines we want
        // to reserve above & below the 5 staff lines.
        let height = StaffMetrics.height(spaceWidth: scaledSpaceWidth,
                                         maxLedgerLines: maxLedgerLines)

        return GeometryReader { geo in
            // Compute the curtain (mask) origin & the playhead X every layout pass.
            let curtainX  = clefRightEdge + clefPaddingInSpaces * scaledSpaceWidth
            let playheadX = curtainX + playheadOffsetInSpaces * scaledSpaceWidth

            ZStack(alignment: .topLeading) {

                // 1) Static staff (clef + 5 lines) – NOT masked,
                //    so the clef remains visible at all times.
                StaffLayer(
                    clef: model.clef,
                    maxLedgerLines: maxLedgerLines,
                    fitsToBounds: false,
                    clefRightEdge: $clefRightEdge
                )
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: .topLeading)
                .allowsHitTesting(false)

                // 2) Fixed red playhead.
                Rectangle()
                    .fill(playheadColor)
                    .frame(width: playheadWidth, height: geo.size.height)
                    .offset(x: playheadX)

                // 3) Scrolling notes (each mini UIMusicStaffView draws its own ledger lines).
                //    This is masked so notes vanish behind the clef instead of overlapping it.
                ZStack(alignment: .topLeading) {
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
                .mask(
                    Rectangle()
                        .frame(
                            width: max(0, geo.size.width - curtainX),
                            height: geo.size.height
                        )
                        .offset(x: curtainX)
                )
            }
            .clipped()
            .onAppear {
                // Push the initial tempo & the “pixels per beat” used for scrolling.
                model.bpm = bpm
                model.updatePixelsPerBeat(pixels: scrollPixelsPerBeat)

                // Synchronize runtime values used by the VM.
                model.updateCanvasWidth(geo.size.width)
                model.updatePlayheadX(playheadX)

                // Kick off the display link.
                model.start()
            }
            .onChange(of: bpm) { newValue in
                // Live tempo changes from the parent slider.
                model.bpm = newValue
            }
            .onChange(of: geo.size) { newSize in
                // Keep the VM updated with the visible width & playhead position.
                model.updateCanvasWidth(newSize.width)
                model.updatePlayheadX(playheadX)
            }
            .onChange(of: clefRightEdge) { _ in
                // If the clef width changes (rotation, resizes…), update playhead.
                model.updatePlayheadX(playheadX)
            }
            .onReceive(model.$payingNote) { note in
                // Bubble the notification up if the caller registered a handler.
                payingNoteHandler?(note)
            }
            .onDisappear {
                model.stop()
            }
        }
        .frame(height: height)
    }
}

// MARK: - Helpers -------------------------------------------------------------

@available(iOS 15.0, *)
private enum StaffMetrics {
    /// Computes the total height of the staff (including the extra space for
    /// ledger lines) such that the *visual* `spaceWidth` stays constant.
    ///
    /// In `UIMusicStaffView`:
    ///   `spaceWidth = height / (6 + (above + below))`
    /// Here `above == below == maxLedgerLines`, so:
    ///   `height = spaceWidth * (6 + 2 * maxLedgerLines)`
    static func height(spaceWidth: CGFloat, maxLedgerLines: Int) -> CGFloat {
        spaceWidth * (6.0 + CGFloat(2 * maxLedgerLines))
    }
}

// MARK: - Static staff (lines + clef) ----------------------------------------

/// A thin `UIViewRepresentable` wrapper around `UIMusicStaffView` used to render
/// the **static** staff and to **measure** the clef’s real width (so we know
/// where to start masking notes and where to place the playhead).
@available(iOS 15.0, *)
private struct StaffLayer: UIViewRepresentable {
    let clef: MusicClef
    let maxLedgerLines: Int
    let fitsToBounds: Bool

    /// The measured **right-most X** of the clef is reported back to SwiftUI.
    @Binding var clefRightEdge: CGFloat

    func makeUIView(context: Context) -> UIMusicStaffView {
        let v = UIMusicStaffView()
        v.elementArray       = [clef]
        v.maxLedgerLines     = maxLedgerLines
        v.shouldDrawClef     = true
        v.shouldDrawNaturals = false
        v.fitsStaffToBounds  = fitsToBounds
        v.spacing            = .uniformTrailingSpace
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIMusicStaffView, context: Context) {
        uiView.elementArray       = [clef]
        uiView.maxLedgerLines     = maxLedgerLines
        uiView.fitsStaffToBounds  = fitsToBounds
        uiView.setNeedsDisplay()

        // Measure the clef width on the *next* run loop to ensure layers are laid out.
        DispatchQueue.main.async {
            guard let clefLayer = uiView.elementDisplayLayer.sublayers?.first else { return }
            // Convert the clef layer frame to the staff view’s coordinate space
            // and extract the **right-most** X (= maxX).
            let frameInView = uiView.layer.convert(clefLayer.frame, from: uiView.elementDisplayLayer)
            let right = frameInView.maxX
            if abs(self.clefRightEdge - right) > 0.5 {
                self.clefRightEdge = right
            }
        }
    }
}

// MARK: - Note micro-view -----------------------------------------------------

/// Wraps a **mini** `UIMusicStaffView` that draws only **one** note (and its extra
/// ledger lines). This allows each note to scroll independently while still using
/// the original UIKit drawing logic.
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

// MARK: - UIKit micro-view: one note + custom ledger lines --------------------

/// Tiny subclass of `UIMusicStaffView` that draws **only** the glyph (note head,
/// stem, accidental…) and **its own** ledger lines. The main staff is hidden for
/// this mini-view so that we can overlay it on top of the static, non-scrolling
/// staff without visual duplication.
@available(iOS 15.0, *)
private final class MiniNoteStaffView: UIMusicStaffView {

    // --- Cached configuration (kept to avoid rebuilding everything each frame)
    private var desiredHeight: CGFloat = 0
    private var cachedNote: MusicNote?
    private var cachedClef: MusicClef = .treble

    /// Extra width of ledger lines relative to the note head width.
    private let ledgerExtraWidthFactor: CGFloat = 1.6

    // MARK: Init

    init(note: MusicNote,
         clef: MusicClef,
         desiredHeight: CGFloat,
         maxLedgerLines: Int) {
        self.desiredHeight = desiredHeight
        self.cachedNote    = note
        self.cachedClef    = clef

        super.init(frame: CGRect(origin: .zero,
                                 size: CGSize(width: 1, height: desiredHeight)))

        // Configuration of the underlying UIMusicStaffView.
        self.maxLedgerLines     = maxLedgerLines
        self.fitsStaffToBounds  = false
        self.shouldDrawClef     = false   // no clef per note
        self.shouldDrawNaturals = false
        self.spacing            = .preferred

        // Hide the staff lines for this mini-view; we only want the glyph + ledgers.
        self.staffColor = .clear

        // Initial element set.
        self.elementArray = [clef, note]
        self.setNeedsDisplay()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public update

    /// Updates the internal state when the SwiftUI wrapper reuses the view.
    func update(note: MusicNote,
                clef: MusicClef,
                desiredHeight: CGFloat,
                maxLedgerLines: Int) {
        self.desiredHeight       = desiredHeight
        self.cachedNote          = note
        self.cachedClef          = clef
        self.maxLedgerLines      = maxLedgerLines
        self.shouldDrawNaturals  = false
        self.elementArray        = [clef, note]

        // Keep our view size consistent; width is mostly irrelevant (we offset).
        var f = self.frame
        f.size.height = desiredHeight
        if f.size.width == 0 { f.size.width = 1 }
        self.frame = f

        self.staffColor = .clear
        self.setNeedsDisplay()
    }

    // MARK: Layout

    /// Ensure the staff stays hidden & the height remains what we requested.
    override func layoutSubviews() {
        super.layoutSubviews()
        if frame.height != desiredHeight {
            frame.size.height = desiredHeight
        }
        self.staffLayer.strokeColor = UIColor.clear.cgColor
    }

    // MARK: Custom ledger lines

    /// We override `setupLayers()` to draw **our own** ledger lines for the single
    /// note we display, so they move perfectly with the glyph.
    override public func setupLayers() {
        super.setupLayers()

        guard let note = cachedNote else { return }

        // Remove previously added custom ledger layers to avoid stacking them up.
        elementDisplayLayer.sublayers?
            .filter { $0.name == "LedgerLinesLayer" }
            .forEach { $0.removeFromSuperlayer() }

        // How many ledger lines do we actually need?
        let req = note.requiredLedgerLines(in: cachedClef)
        guard req != 0 else { return }

        // Robust bounding box that encloses all note-related sublayers (head/stem/accidental).
        let bbox = elementDisplayLayer.sublayers?
            .reduce(into: CGRect.null) { rect, layer in
                rect = rect.union(layer.frame)
            } ?? .zero

        // Compute line width and position around the note head.
        let centerX        = bbox.midX
        let headApproxWidth = bbox.width
        let w = max(headApproxWidth * ledgerExtraWidthFactor, spaceWidth * 2.0)

        // Staff centerline provided by UIMusicStaffView (now public via `staffCenterlineY`).
        let centerY = self.staffCenterlineY

        // Build one path containing all ledger segments.
        let path = CGMutablePath()

        if req > 0 {
            // Above the staff
            for i in 0..<req {
                let y = centerY - (CGFloat(3 + i) * self.spaceWidth)
                path.move(to: CGPoint(x: centerX - w / 2, y: y))
                path.addLine(to: CGPoint(x: centerX + w / 2, y: y))
            }
        } else {
            // Below the staff
            for i in 0..<abs(req) {
                let y = centerY + (CGFloat(3 + i) * self.spaceWidth)
                path.move(to: CGPoint(x: centerX - w / 2, y: y))
                path.addLine(to: CGPoint(x: centerX + w / 2, y: y))
            }
        }

        // Final layer that we add on top of the note layers.
        let ledger = CAShapeLayer()
        ledger.name         = "LedgerLinesLayer"
        ledger.path         = path
        ledger.strokeColor  = UIColor.label.cgColor
        ledger.lineWidth    = self.staffLineThickness
        ledger.fillColor    = UIColor.clear.cgColor
        ledger.contentsScale = UIScreen.main.scale
        ledger.lineCap      = .round

        elementDisplayLayer.addSublayer(ledger)
    }
}
