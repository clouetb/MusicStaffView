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

    // ---------- Public configuration ----------
    private let maxLedgerLines: Int
    private let spaceWidth: CGFloat
    private let beatGapBetweenNotes: Double
    private let visualScale: CGFloat
    
    /// Petit padding (en espaces) ajouté à la largeur mesurée de la clé
    private let clefPaddingInSpaces: CGFloat = 0.3

    // ---------- Reactive model ----------
    @StateObject private var model: ScrollingMusicStaffViewModel
    
    // ---------- Mesure runtime ----------
    /// Largeur *réelle* (en points) de la clé de sol (mesurée côté UIKit)
    @State private var clefPixelWidth: CGFloat = 0

    // MARK: - Init
    public init(
        bpm: Double,
        clef: MusicClef = .treble,
        spacingStrategy: NoteSpacingStrategy = .fromPreferredOrDefault(),
        initialNotes: [MusicNote] = [],
        maxLedgerLines: Int = 4,
        spaceWidth: CGFloat = 8,
        beatGapBetweenNotes: Double = 1.0,
        visualScale: CGFloat = 1.2            // +20% par défaut
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

    // MARK: - Body
    public var body: some View {
        let scaledSpaceWidth = spaceWidth * visualScale
        let height = StaffMetrics.height(spaceWidth: scaledSpaceWidth,
                                         maxLedgerLines: maxLedgerLines)

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                // 1) Portée fixe (clé + 5 lignes) – NON masquée
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

                // 2) Notes + ledger lines – MASQUÉES à gauche du rideau
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

// MARK: - Staff metrics helper

@available(iOS 15.0, *)
private enum StaffMetrics {
    static func height(spaceWidth: CGFloat, maxLedgerLines: Int) -> CGFloat {
        spaceWidth * (6.0 + CGFloat(2 * maxLedgerLines))
    }
}

// MARK: - Static staff (lines + clef, sans notes)

@available(iOS 15.0, *)
private struct StaffLayer: UIViewRepresentable {
    let clef: MusicClef
    let maxLedgerLines: Int
    let fitsToBounds: Bool
    
    /// Binding pour renvoyer vers SwiftUI la largeur *réelle* de la clé
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
        
        // Mesure **robuste** : le premier sublayer de elementDisplayLayer correspond à la clé
        DispatchQueue.main.async {
            guard let clefLayer = uiView.elementDisplayLayer.sublayers?.first else { return }
            let width = clefLayer.bounds.width
            if abs(self.clefWidth - width) > 0.5 {
                self.clefWidth = width
            }
        }
    }
}

// MARK: - One note wrapper

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

// MARK: - UIKit micro-view: draws the note + its own moving ledger lines

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

        // on cache la portée de cette mini-vue (on ne veut que la note + ledger lines)
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
        let headApproxWidth = bbox.width
        let w = max(headApproxWidth * ledgerExtraWidthFactor, spaceWidth * 2.0)

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
