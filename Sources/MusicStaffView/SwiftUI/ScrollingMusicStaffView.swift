//
//  ScrollingMusicStaffView.swift
//  MusicStaffView – Scrolling extension
//
//  Created: 24 Jul 2025
//

import SwiftUI
import Music
import UIKit

/// A SwiftUI wrapper that shows a static staff (clef + 5 lines) and
/// a stream of scrolling notes rendered on top, while hiding any note
/// that would visually pass under the clef using a left-side mask.
@available(iOS 15.0, *)
public struct ScrollingMusicStaffView: View {

    // MARK: - Public, immutable configuration

    /// Maximum number of ledger lines that the underlying UIKit view is allowed to draw.
    private let maxLedgerLines: Int

    /// Base staff "space" height, in points, before visual scaling is applied.
    private let spaceWidth: CGFloat

    /// Extra horizontal spacing between two notes, expressed in beats.
    private let beatGapBetweenNotes: Double

    /// Global visual scale factor applied to the staff height (and thus to `spaceWidth`).
    private let visualScale: CGFloat

    /// Small padding (in staff *spaces*) added to the measured clef width
    /// to decide where the left-side mask (the "curtain") starts.
    private let clefPaddingInSpaces: CGFloat = 0.3

    // MARK: - Reactive model

    /// The view model that drives time, positions and culling.
    @StateObject private var model: ScrollingMusicStaffViewModel

    // MARK: - Runtime measurements

    /// Measured clef width (in points) coming from the UIKit staff view.
    @State private var clefPixelWidth: CGFloat = 0

    // MARK: - Initializer

    public init(
        bpm: Double,
        clef: MusicClef = .treble,
        spacingStrategy: NoteSpacingStrategy = .fromPreferredOrDefault(),
        initialNotes: [MusicNote] = [],
        maxLedgerLines: Int = 4,
        spaceWidth: CGFloat = 8,
        beatGapBetweenNotes: Double = 1.0,
        visualScale: CGFloat = 1.2   // +20% by default
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

        self.maxLedgerLines       = maxLedgerLines
        self.spaceWidth           = spaceWidth
        self.beatGapBetweenNotes  = beatGapBetweenNotes
        self.visualScale          = visualScale
    }

    // MARK: - Body

    public var body: some View {
        // We enlarge the staff visually by scaling the space height.
        let scaledSpaceWidth = spaceWidth * visualScale
        let height = StaffMetrics.height(spaceWidth: scaledSpaceWidth,
                                         maxLedgerLines: maxLedgerLines)

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                // 1) Static staff (clef + 5 lines) – NOT masked.
                StaffLayer(
                    clef: model.clef,
                    maxLedgerLines: maxLedgerLines,
                    fitsToBounds: false,
                    clefWidth: $clefPixelWidth
                )
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: .topLeading)
                .allowsHitTesting(false)

                // 2) Moving notes (each one draws its own ledger lines),
                //    masked on the left so they disappear before going under the clef.
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
                            width: max(
                                0,
                                geo.size.width - (clefPixelWidth + clefPaddingInSpaces * scaledSpaceWidth)
                            ),
                            height: geo.size.height
                        )
                        .offset(x: clefPixelWidth + clefPaddingInSpaces * scaledSpaceWidth)
                )
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
        .frame(height: height)
    }

    // MARK: - Public API passthroughs

    /// Change tempo on the fly.
    public func setBPM(_ newBPM: Double) {
        model.bpm = newBPM
    }

    /// Enqueue extra notes to scroll in from the right.
    public func addNotes(_ notes: [MusicNote]) {
        let inputs = notes.map {
            ScrollingMusicStaffViewModel.ScrollingNoteInput($0, duration: .quarter)
        }
        model.enqueue(inputs)
    }

    /// Convenience access to the left-most visible note.
    public var leftMostVisibleNote: MusicNote? {
        model.leftMostVisibleNote
    }
}

// MARK: - Staff metrics

@available(iOS 15.0, *)
private enum StaffMetrics {
    /// Computes the full height for a staff that reserves room for
    /// `maxLedgerLines` above and below, assuming `fitsStaffToBounds == false`.
    static func height(spaceWidth: CGFloat, maxLedgerLines: Int) -> CGFloat {
        spaceWidth * (6.0 + CGFloat(2 * maxLedgerLines))
    }
}

// MARK: - Static staff (clef + 5 lines, no notes)

@available(iOS 15.0, *)
private struct StaffLayer: UIViewRepresentable {
    let clef: MusicClef
    let maxLedgerLines: Int
    let fitsToBounds: Bool

    /// Binding used to report the measured clef width (in points) back to SwiftUI.
    @Binding var clefWidth: CGFloat

    func makeUIView(context: Context) -> UIMusicStaffView {
        let v = UIMusicStaffView()
        v.elementArray = [clef]
        v.maxLedgerLines = maxLedgerLines
        v.shouldDrawClef = true
        v.shouldDrawNaturals = false
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

        // Measure the clef width after layout: the first sublayer of elementDisplayLayer
        // is the clef (since elementArray = [clef]).
        DispatchQueue.main.async {
            guard let clefLayer = uiView.elementDisplayLayer.sublayers?.first else { return }
            let width = clefLayer.bounds.width
            if abs(self.clefWidth - width) > 0.5 {
                self.clefWidth = width
            }
        }
    }
}

// MARK: - One scrolling note wrapper

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

// MARK: - UIKit micro view for a single note (with its own ledger lines)

@available(iOS 15.0, *)
private final class MiniNoteStaffView: UIMusicStaffView {

    // Cached state
    private var desiredHeight: CGFloat = 0
    private var cachedNote: MusicNote?
    private var cachedClef: MusicClef = .treble

    /// Multiplier used to define the drawn ledger line length relative to the note head’s width.
    private let ledgerExtraWidthFactor: CGFloat = 1.6

    // MARK: Init

    init(note: MusicNote,
         clef: MusicClef,
         desiredHeight: CGFloat,
         maxLedgerLines: Int) {
        self.desiredHeight = desiredHeight
        self.cachedNote = note
        self.cachedClef = clef

        super.init(frame: CGRect(origin: .zero,
                                 size: CGSize(width: 1, height: desiredHeight)))

        self.maxLedgerLines = maxLedgerLines
        self.fitsStaffToBounds = false
        self.shouldDrawClef = false
        self.shouldDrawNaturals = false
        self.spacing = .preferred

        // Hide the staff lines in this per-note view: we only want the glyph + ledger lines.
        self.staffColor = .clear

        self.elementArray = [clef, note]
        self.setNeedsDisplay()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public update API

    func update(note: MusicNote,
                clef: MusicClef,
                desiredHeight: CGFloat,
                maxLedgerLines: Int) {
        self.desiredHeight = desiredHeight
        self.cachedNote = note
        self.cachedClef = clef

        self.maxLedgerLines = maxLedgerLines
        self.shouldDrawNaturals = false
        self.elementArray = [clef, note]

        var f = self.frame
        f.size.height = desiredHeight
        if f.size.width == 0 { f.size.width = 1 }
        self.frame = f

        self.staffColor = .clear
        self.setNeedsDisplay()
    }

    // MARK: - Layout & drawing

    override func layoutSubviews() {
        super.layoutSubviews()
        if frame.height != desiredHeight {
            frame.size.height = desiredHeight
        }
        // Ensure the underlying staff stays hidden.
        self.staffLayer.strokeColor = UIColor.clear.cgColor
    }

    /// We override `setupLayers()` to add custom ledger lines that move with the note.
    override public func setupLayers() {
        super.setupLayers()

        guard let note = cachedNote else { return }

        // Remove any previous custom ledger layers.
        elementDisplayLayer.sublayers?
            .filter { $0.name == "LedgerLinesLayer" }
            .forEach { $0.removeFromSuperlayer() }

        // How many ledger lines does this note need?
        let req = note.requiredLedgerLines(in: cachedClef)
        guard req != 0 else { return }

        // Compute a robust bounding box for the note head and its accessories.
        let bbox = elementDisplayLayer.sublayers?
            .reduce(into: CGRect.null) { rect, layer in
                rect = rect.union(layer.frame)
            } ?? .zero

        let centerX = bbox.midX
        let headApproxWidth = bbox.width
        let w = max(headApproxWidth * ledgerExtraWidthFactor, spaceWidth * 2.0)

        // Vertical centerline provided by UIMusicStaffView.
        let centerY = self.staffCenterlineY

        // Draw the ledger lines above/below, starting from the first line outside the 5-line staff.
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

        let ledger = CAShapeLayer()
        ledger.name = "LedgerLinesLayer"
        ledger.path = path
        ledger.strokeColor = UIColor.label.cgColor
        ledger.lineWidth = self.staffLineThickness
        ledger.fillColor = UIColor.clear.cgColor
        ledger.contentsScale = UIScreen.main.scale
        ledger.lineCap = .round

        elementDisplayLayer.addSublayer(ledger)
    }
}
