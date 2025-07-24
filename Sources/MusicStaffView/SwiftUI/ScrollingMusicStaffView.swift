//
//  ScrollingMusicStaffView.swift
//  MusicStaffView – Scrolling extension
//
//  24 Jul 2025
//

import SwiftUI
import Music
import UIKit

@available(iOS 15.0, *)
public struct ScrollingMusicStaffView: View {

    private let maxLedgerLines: Int
    private let spaceWidth: CGFloat
    private let beatGapBetweenNotes: Double
    private let visualScale: CGFloat
    
    @StateObject private var model: ScrollingMusicStaffViewModel

    public init(
        bpm: Double,
        clef: MusicClef = .treble,
        spacingStrategy: NoteSpacingStrategy = .fromPreferredOrDefault(),
        initialNotes: [MusicNote] = [],
        maxLedgerLines: Int = 4,
        spaceWidth: CGFloat = 8,
        beatGapBetweenNotes: Double = 1.0,
        visualScale: CGFloat = 1.2            // ⬅️ +20% par défaut
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
        self.visualScale = visualScale
    }

    public var body: some View {
        let scaledSpaceWidth = spaceWidth * visualScale
        let height = StaffMetrics.height(spaceWidth: scaledSpaceWidth,
                                         maxLedgerLines: maxLedgerLines)

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                StaffLayer(
                    clef: model.clef,
                    maxLedgerLines: maxLedgerLines,
                    fitsToBounds: false
                )
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: .topLeading)
                .allowsHitTesting(false)

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
        .frame(height: height)
    }

    public func setBPM(_ newBPM: Double) {
        model.bpm = newBPM
    }

    public func addNotes(_ notes: [MusicNote]) {
        let inputs = notes.map {
            ScrollingMusicStaffViewModel.ScrollingNoteInput($0, duration: .quarter)
        }
        model.enqueue(inputs)
    }

    public var leftMostVisibleNote: MusicNote? {
        model.leftMostVisibleNote
    }
}

@available(iOS 15.0, *)
private enum StaffMetrics {
    static func height(spaceWidth: CGFloat, maxLedgerLines: Int) -> CGFloat {
        spaceWidth * (6.0 + CGFloat(2 * maxLedgerLines))
    }
}

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
    }
}

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

@available(iOS 15.0, *)
private final class MiniNoteStaffView: UIMusicStaffView {

    private var desiredHeight: CGFloat = 0
    private var cachedNote: MusicNote?
    private var cachedClef: MusicClef = .treble

    private let ledgerExtraWidthFactor: CGFloat = 1.6

    init(note: MusicNote,
         clef: MusicClef,
         desiredHeight: CGFloat,
         maxLedgerLines: Int)
    {
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

        // on cache la portée de cette mini-vue
        self.staffColor = .clear

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

    override func layoutSubviews() {
        super.layoutSubviews()
        if frame.height != desiredHeight {
            frame.size.height = desiredHeight
        }
        self.staffLayer.strokeColor = UIColor.clear.cgColor
    }

    override public func setupLayers() {
        super.setupLayers()

        guard let note = cachedNote else { return }

        // supprime les précédentes
        elementDisplayLayer.sublayers?
            .filter { $0.name == "LedgerLinesLayer" }
            .forEach { $0.removeFromSuperlayer() }

        let req = note.requiredLedgerLines(in: cachedClef)
        guard req != 0 else { return }

        // bounding box de la note (et accessoires) pour obtenir un X central robuste
        let bbox = elementDisplayLayer.sublayers?
            .reduce(into: CGRect.null) { rect, layer in
                rect = rect.union(layer.frame)
            } ?? .zero

        let centerX = bbox.midX
        let headApproxWidth = bbox.width   // pas parfait, mais suffisant pour dimensionner les traits
        let w = max(headApproxWidth * ledgerExtraWidthFactor, spaceWidth * 2.0)

        // utilise le centre fourni par UIMusicStaffView
        let centerY = self.staffCenterlineY

        let path = CGMutablePath()

        if req > 0 {
            for i in 0..<req {
                let y = centerY - (CGFloat(3 + i) * self.spaceWidth)
                path.move(to: CGPoint(x: centerX - w / 2, y: y))
                path.addLine(to: CGPoint(x: centerX + w / 2, y: y))
            }
        } else {
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
