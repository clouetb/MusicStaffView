//
//  UIMusicStaffView.swift
//  Music
//
//  Created by Mike Muszynski on 1/4/15.
//  Copyright (c) 2015 Mike Muszynski. All rights reserved.
//

import Music

#if os(iOS)
import UIKit
public typealias ViewType  = UIView
public typealias ColorType = UIColor
#elseif os(macOS)
import Cocoa
public typealias ViewType  = NSView
public typealias ColorType = NSColor
#endif

// MARK: - Private helper to keep track of accessories with a reference to their parent

/// Wraps an accessory so it can “know” its parent element (needed to compute offsets correctly
/// in a purely protocol-oriented design).
fileprivate struct AccessoryElementWithParent: MusicStaffViewElement {
    func path(in frame: CGRect) -> CGPath {
        accessory.path(in: frame)
    }

    var aspectRatio: CGFloat          { accessory.aspectRatio }
    var heightInStaffSpace: CGFloat   { accessory.heightInStaffSpace }
    var anchorPoint: CGPoint          { accessory.anchorPoint }

    var parent: any MusicStaffViewElement
    var accessory: MusicStaffViewAccessory

    init(parent: any MusicStaffViewElement, accessory: MusicStaffViewAccessory) {
        self.parent     = parent
        self.accessory  = accessory
    }

    func offset(in clef: MusicClef) -> Int {
        accessory.offset(in: clef) + parent.offset(in: clef)
    }
}

// MARK: - UIMusicStaffView

/// A Core Animation–backed view that draws a musical staff, a clef and a sequence of elements
/// (notes, accidentals, shims, key signatures, etc.). It supports several horizontal spacing modes,
/// optional masking of ledger lines, and scales to fit if requested.
@IBDesignable
open class UIMusicStaffView: ViewType {

    // MARK: - Public types

    /// How horizontal spacing between elements is computed.
    public enum SpacingType {
        /// Use `preferredHorizontalSpacing` between elements.
        case preferred

        /// Spread elements uniformly across the full available width, with no outer margins.
        case uniformFullWidth

        /// Spread elements uniformly and add an extra flexible space at the trailing edge.
        case uniformTrailingSpace

        /// Spread elements uniformly and add equal flexible spaces at both leading and trailing edges.
        case uniformLeadingAndTrailingSpace
    }

    // MARK: - Interface Builder support

    /// Number of notes to preview in Interface Builder (hardcoded notes).
    @IBInspectable private var previewNotes: Int = 8 {
        didSet { self.setupLayers() }
    }

    // MARK: - Public configuration

    /// When `false` (default), reserve enough vertical space above/below to allow
    /// the same `spaceWidth` across instances, even if they don't need ledger lines.
    /// When `true`, the staff will be scaled to fit exactly in the current bounds.
    @IBInspectable public var fitsStaffToBounds = false

    /// Maximum number of ledger lines to draw above and below the five-line staff.
    @IBInspectable public var maxLedgerLines: Int = 0 {
        didSet { self.setupLayers() }
    }

    /// Preferred horizontal spacing (in points) used when `spacing == .preferred`.
    @IBInspectable public var preferredHorizontalSpacing: CGFloat = 0.0 {
        didSet { self.setupLayers() }
    }

    /// Whether the clef should be drawn.
    @IBInspectable public var shouldDrawClef: Bool = true {
        didSet { self.setupLayers() }
    }

    /// Whether to draw natural accidentals even when the note’s accidental is `.natural`.
    @IBInspectable public var shouldDrawNaturals: Bool = true {
        didSet { self.setupLayers() }
    }

    /// When enabled, bright translucent boxes are drawn to show frames/bounds of each element layer.
    @IBInspectable public var debug: Bool = false {
        didSet { self.setupLayers() }
    }

    /// Whether to draw all accidentals regardless of key signature carry-over behavior.
    public var drawAllAccidentals: Bool = false

    /// Horizontal spacing strategy.
    public var spacing: SpacingType = .uniformTrailingSpace {
        didSet { self.setupLayers() }
    }

    // MARK: - Public colors

    #if os(iOS)
    public var staffColor: ColorType   = .secondaryLabel
    public var elementColor: ColorType = .label
    #elseif os(macOS)
    public var staffColor: ColorType   = .secondaryLabelColor
    public var elementColor: ColorType = .labelColor
    #endif

    // MARK: - Public (read-only) helpers for outside consumers (e.g. SwiftUI wrappers)

    /// Vertical Y coordinate (in view coordinates) of the staff center line (the 3rd line).
    /// Exposed to allow external layers to align correctly to the staff.
    public var staffCenterlineY: CGFloat { centerlineHeight }

    /// The line thickness used by the staff. Helpful to draw ledger lines that visually match the staff.
    public var staffLineThickness: CGFloat { staffLayer.lineWidth }

    // MARK: - Internal computed values

    /// The array of elements to draw. Setting it re-triggers a full layout/re-draw.
    public var elementArray: [MusicStaffViewElement] {
        get {
            #if TARGET_INTERFACE_BUILDER
            // Fallback content for IB previews — not used at runtime.
            var testArray: [MusicStaffViewElement] = [
                MusicClef.treble,
                MusicNote(pitch: MusicPitch(name: .b, accidental: .sharp, octave: 4), rhythm: .quarter),
                MusicNote(pitch: MusicPitch(name: .b, accidental: .sharp, octave: 4), rhythm: .quarter),
                MusicNote(pitch: MusicPitch(name: .b, accidental: .sharp, octave: 4), rhythm: .quarter)
            ]
            return testArray
            #else
            return _elementArray
            #endif
        }
        set { _elementArray = newValue }
    }

    /// The height of one staff *space* in points (read-only).
    /// Formula from the original implementation:
    ///   spaceWidth = bounds.height / (6 + ledgerAbove + ledgerBelow)
    var spaceWidth: CGFloat {
        return self.bounds.size.height / (6.0 + CGFloat(self.ledgerLines.above + self.ledgerLines.below))
    }

    /// The vertical position of the center line (3rd line) in view coordinates.
    /// Kept `internal` (default) so SwiftUI wrappers can access it, not `private`.
    var centerlineHeight: CGFloat {
        let ledgerOffset = CGFloat(ledgerLines.above - ledgerLines.below) * self.spaceWidth / 2.0
        return self.bounds.size.height / 2.0 + ledgerOffset
    }

    // MARK: - Private stored state

    /// Backing storage for `elementArray`.
    private var _elementArray: [MusicStaffViewElement] = [] {
        didSet { self.setupLayers() }
    }

    /// Current clef being drawn, cached so elements can compute offsets correctly.
    private var displayedClef: MusicClef = .treble

    /// The staff layer that draws lines and ledger lines (masked).
    var staffLayer = MusicStaffViewStaffLayer()

    /// Container layer that draws all the musical elements (notes, accidentals, clefs, …).
    var elementDisplayLayer = CALayer()

    /// Counts how many ledger lines need to be reserved above/below when `fitsStaffToBounds == true`.
    private var ledgerLines: (above: Int, below: Int) {
        // When we do not fit to bounds, just reserve a symmetrical amount (maxLedgerLines)
        // and expose that to the staff layer.
        guard self.fitsStaffToBounds else {
            let lines = (above: maxLedgerLines, below: maxLedgerLines)
            self.staffLayer.ledgerLines = lines
            return lines
        }

        // Otherwise, compute the actual number of ledger lines required by elements.
        let lines = elementArray.reduce((above: 0, below: 0)) { (result, element) -> (above: Int, below: Int) in
            var result = result
            let elementLedgerLines = element.requiredLedgerLines(in: self.displayedClef)
            if elementLedgerLines > 0 {
                result.above = max(result.above, elementLedgerLines)
            } else if elementLedgerLines < 0 {
                result.below = max(result.below, abs(elementLedgerLines))
            }
            return result
        }

        self.staffLayer.ledgerLines = lines
        return lines
    }

    // MARK: - View life cycle

    /// Rebuild all Core Animation layers representing both the staff and the elements.
    ///
    /// This method:
    /// 1. Recomputes the list of elements + spacing shims
    /// 2. Distributes them horizontally using the selected `spacing` strategy
    /// 3. Builds and positions CALayers for each element
    /// 4. Builds the staff (5 lines + ledger lines) and masks out unnecessary ledger segments
    /// 5. Optionally scales the whole thing to fit `bounds` if `fitsStaffToBounds == true`
    public func setupLayers() {
        // Interface Builder sometimes triggers setup with a zero rect — skip in that case.
        guard self.bounds != .zero else { return }

        // ---- Reset / recreate the two main container layers
        staffLayer.removeFromSuperlayer()
        staffLayer = MusicStaffViewStaffLayer()
        staffLayer.frame = self.bounds

        elementDisplayLayer.removeFromSuperlayer()
        elementDisplayLayer = CALayer()
        elementDisplayLayer.frame = self.bounds

        // ---- Flatten the declared elements into a full list including shims and accessories
        var elements = [MusicStaffViewElement]()

        for element in elementArray {
            // Skip clef if we are not supposed to draw it.
            guard !(element is MusicClef && !shouldDrawClef) else { continue }

            // Handle accessories (accidentals, articulations, etc.)
            for accessory in element.accessoryElements {
                switch accessory.placement {

                // Not supported in this spacing engine.
                case .above, .below, .standalone:
                    fatalError("These placements are not yet implemented")

                case .leading:
                    // Optionally skip natural accidentals.
                    if let accessory = accessory as? MusicAccidental, accessory == .natural, !shouldDrawNaturals {
                        continue
                    }

                    let finalAccessory = AccessoryElementWithParent(parent: element, accessory: accessory)
                    elements.append(finalAccessory)

                    let shim = MusicStaffViewShim(width: preferredHorizontalSpacing, spaceWidth: spaceWidth)
                    elements.append(shim)

                case .trailing:
                    // The parent element will add a flexible shim; we must convert it to a static one.
                    if var lastShim = elements.last as? MusicStaffViewShim {
                        lastShim.isFlexible = false
                        lastShim.width = preferredHorizontalSpacing
                    }
                    elements.append(accessory)

                    var flexShim = MusicStaffViewShim(width: 0.0, spaceWidth: spaceWidth)
                    flexShim.isFlexible = true
                    elements.append(flexShim)
                }
            }

            // Add the element itself
            elements.append(element)

            // And a flexible shim right after (unless it's a shim itself).
            if !(element is MusicStaffViewShim) {
                var flexShim = MusicStaffViewShim(width: 0.0, spaceWidth: spaceWidth)
                flexShim.isFlexible = true
                elements.append(flexShim)
            }
        }

        // ---- Compute total intrinsic width of all elements (with their preferred widths)
        let totalElementWidth = elements.reduce(0.0) { total, nextElement in
            total + nextElement.layer(in: displayedClef,
                                      withSpaceWidth: spaceWidth,
                                      color: nil).bounds.width
        }

        // ---- Deduce the width of the flexible shims (if any) depending on spacing mode
        var flexWidth: CGFloat = preferredHorizontalSpacing

        func setFlexWidth() {
            let viewWidth  = self.bounds.size.width
            let extraWidth = viewWidth - totalElementWidth

            let numFlexible = elements.filter { ($0 as? MusicStaffViewShim)?.isFlexible == true }.count

            if elements.count > 0 {
                if numFlexible == 0 || extraWidth < 0 {
                    print("There were either zero flexible elements or their widths would be negative. Reverting to preferred horizontal spacing.")
                    flexWidth = preferredHorizontalSpacing
                } else {
                    flexWidth = extraWidth / CGFloat(numFlexible)
                }
            }
        }

        switch self.spacing {
        case .preferred:
            break

        case .uniformFullWidth:
            // Drop the very last shim.
            if elements.last is MusicStaffViewShim {
                _ = elements.removeLast()
            }
            setFlexWidth()

        case .uniformLeadingAndTrailingSpace:
            // Insert a leading flexible shim
            var flexShim = MusicStaffViewShim(width: 0.0, spaceWidth: self.spaceWidth)
            flexShim.isFlexible = true
            elements.insert(flexShim, at: 0)
            setFlexWidth()

        case .uniformTrailingSpace:
            setFlexWidth()
        }

        // ---- Build the actual CALayers
        var elementHorizontalPositions = [CGFloat]()
        var elementLayers = [CALayer]()
        var ledgerLineElementIndices = [Int]() // (kept for parity with the original code)

        var currentPosition: CGFloat = 0.0

        for element in elements {
            // If a clef is seen in the stream, update the `displayedClef` used for vertical offsets.
            if let newClef = element as? MusicClef {
                self.displayedClef = newClef
            }

            let layers: [CALayer]
            if var element = element as? MusicStaffViewShim {
                if element.isFlexible {
                    element.width = flexWidth
                }
                element.spaceWidth = self.spaceWidth
                layers = self.layers(for: element, atHorizontalPosition: currentPosition)
            } else {
                layers = self.layers(for: element, atHorizontalPosition: currentPosition)
            }

            elementLayers.append(contentsOf: layers)

            // Advance the running X position to the end of the last created layer.
            currentPosition = (elementLayers.last?.frame.origin.x ?? 0)
                            + (elementLayers.last?.frame.size.width ?? 0)

            if element.requiresLedgerLines(in: self.displayedClef) {
                ledgerLineElementIndices.append(elementHorizontalPositions.count)
            }
            elementHorizontalPositions.append(currentPosition)

            // --- Compute unmasked rects for ledger lines (so they remain visible only around the glyph)
            func extensionFromCenterLine(for rect: CGRect, fullHeight: Bool) -> CGRect {
                let centerLine = self.centerlineHeight
                let minY = rect.minY + (fullHeight ? 0 : self.staffLayer.lineWidth)
                let maxY = rect.maxY

                let rectSize = CGSize(width: rect.size.width, height: self.spaceWidth * 4.0)
                let rectOrigin = CGPoint(x: rect.origin.x, y: centerLine - self.spaceWidth * 2.0)
                var extentsRect = CGRect(origin: rectOrigin, size: rectSize)

                if minY < centerLine - spaceWidth * 2.0 {
                    extentsRect.origin.y = minY
                    extentsRect.size.height += centerLine - self.spaceWidth * 2.0 - minY
                }

                if maxY > centerLine + spaceWidth * 2.0 {
                    extentsRect.size.height += maxY - (centerLine + spaceWidth * 2.0) - (fullHeight ? 0 : self.staffLayer.lineWidth)
                }

                return extentsRect
            }

            // Register the unmasked region for the staff layer mask.
            for layer in layers {
                if element.requiresLedgerLines(in: self.displayedClef) {
                    let maskRect = extensionFromCenterLine(for: layer.frame,
                                                           fullHeight: !(element is MusicNote))
                    staffLayer.unmaskRects.append(maskRect)
                }
            }
        }

        // Add all element layers to the display layer
        for layer in elementLayers {
            self.elementDisplayLayer.addSublayer(layer)
        }

        // ---- Build the staff + mask
        staffLayer.maxLedgerLines = self.maxLedgerLines
        let mask = staffLayer.staffLineMask!

        if debug {
            mask.backgroundColor = ColorType(red: 1.0, green: 0.0, blue: 1.0, alpha: 0.5).cgColor
            staffLayer.backgroundColor = ColorType(red: 1.0, green: 0, blue: 0, alpha: 0.25).cgColor
            staffLayer.addSublayer(mask)
        }

        staffLayer.strokeColor = staffColor.cgColor
        staffLayer.mask = mask

        // ---- Add both top-level layers to the view
        #if os(iOS)
        self.layer.addSublayer(staffLayer)
        self.layer.addSublayer(elementDisplayLayer)
        #elseif os(macOS)
        self.layer?.addSublayer(staffLayer)
        self.layer?.addSublayer(elementDisplayLayer)
        #endif

        // ---- Optionally scale to fit bounds
        if self.fitsStaffToBounds {
            guard
                let mask = staffLayer.staffLineMask as? CAShapeLayer,
                let bounds = mask.path?.boundingBox,
                bounds.width > 0,
                bounds.height > 0
            else {
                return
            }

            let scaleAmt = min(self.bounds.width / bounds.width,
                               self.bounds.height / bounds.height)

            let scale     = CATransform3DMakeScale(scaleAmt, scaleAmt, 1.0)
            let translate = CATransform3DMakeTranslation(-bounds.origin.x, bounds.origin.y, 0)

            #if os(iOS)
            for layer in self.layer.sublayers! {
                layer.transform = CATransform3DConcat(translate, scale)
            }
            #elseif os(macOS)
            for layer in self.layer!.sublayers! {
                layer.transform = CATransform3DConcat(translate, scale)
            }
            #endif
        }
    }

    // MARK: - Layer creation helper

    /// Builds the Core Animation layers for a given element at the specified X position.
    /// Returns the layers so the caller can add them to `elementDisplayLayer`.
    private func layers(for element: MusicStaffViewElement,
                        atHorizontalPosition xPosition: CGFloat) -> [CALayer] {
        var elementLayers = [CALayer]()

        var layer = element.layer(in: displayedClef,
                                  withSpaceWidth: self.spaceWidth,
                                  color: self.elementColor)

        if debug {
            layer.backgroundColor = ColorType(red: 0.0, green: 1.0, blue: 0, alpha: 0.25).cgColor
        }

        // Shims are invisible (clear color).
        if element is MusicStaffViewShim {
            layer = element.layer(in: displayedClef,
                                  withSpaceWidth: self.spaceWidth,
                                  color: .clear)
        }

        // Flip vertically for downward stems.
        if element.direction(in: self.displayedClef) == .down {
            layer.transform = CATransform3DMakeRotation(CGFloat(Double.pi), 0, 0, 1.0)
        }

        var elementPosition = layer.position
        elementPosition.x += xPosition
        elementPosition.y += centerlineHeight
        elementPosition.x += layer.bounds.width * 0.5
        layer.position = elementPosition

        elementLayers.append(layer)
        return elementLayers
    }

    // MARK: - Utilities

    /// Converts a staff offset (e.g. number of half-spaces from the middle line)
    /// into a view coordinate offset in points.
    private func viewOffsetForStaffOffset(_ offset: Int) -> CGFloat {
        let offsetFloat = CGFloat(offset)
        return -self.bounds.size.height / 2.0 + offsetFloat * spaceWidth / 2.0
    }

    // MARK: - Interface Builder hooks

    override open func prepareForInterfaceBuilder() {
        Task {
            await self.setupLayers()
        }
    }

    // MARK: - (macOS) Resizing hooks

    #if os(macOS)
    open override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        self.setupLayers()
    }

    open override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        self.setupLayers()
    }

    #elseif os(iOS)

    // MARK: - (iOS) Layout hook

    open override func layoutSubviews() {
        super.layoutSubviews()
        self.setupLayers()
    }

    #endif
}
