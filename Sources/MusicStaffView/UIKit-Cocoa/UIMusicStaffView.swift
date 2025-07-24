//
//  MusicStaffView.swift
//  Music
//
//  Created by Mike Muszynski on 1/4/15.
//  Copyright (c) 2015 Mike Muszynski. All rights reserved.
//

import Music

#if os(iOS)
import UIKit
public typealias ViewType = UIView
public typealias ColorType = UIColor
#elseif os(macOS)
import Cocoa
public typealias ViewType = NSView
public typealias ColorType = NSColor
#endif

fileprivate struct AccessoryElementWithParent: MusicStaffViewElement {
    func path(in frame: CGRect) -> CGPath {
        accessory.path(in: frame)
    }
    
    var aspectRatio: CGFloat { accessory.aspectRatio }
    var heightInStaffSpace: CGFloat { accessory.heightInStaffSpace }
    var anchorPoint: CGPoint { accessory.anchorPoint }
    
    var parent: any MusicStaffViewElement
    var accessory: MusicStaffViewAccessory
    
    init(parent: any MusicStaffViewElement, accessory: MusicStaffViewAccessory) {
        self.parent = parent
        self.accessory = accessory
    }
    
    func offset(in clef: MusicClef) -> Int {
        accessory.offset(in: clef) + parent.offset(in: clef)
    }
}

@IBDesignable open class UIMusicStaffView: ViewType {
    public enum SpacingType {
        case preferred
        case uniformFullWidth
        case uniformTrailingSpace
        case uniformLeadingAndTrailingSpace
    }
    
    @IBInspectable private var previewNotes: Int = 8 {
        didSet {
            self.setupLayers()
        }
    }
    
    @IBInspectable public var fitsStaffToBounds = false
    
    private var _elementArray: [MusicStaffViewElement] = [] {
        didSet {
            self.setupLayers()
        }
    }
    
    public var elementArray: [MusicStaffViewElement] {
        get {
#if TARGET_INTERFACE_BUILDER
            var testArray: [MusicStaffViewElement] = [MusicClef.treble,
                                                      MusicNote(pitch: MusicPitch(name: .b, accidental: .sharp, octave: 4), rhythm: .quarter),
                                                      MusicNote(pitch: MusicPitch(name: .b, accidental: .sharp, octave: 4), rhythm: .quarter),
                                                      MusicNote(pitch: MusicPitch(name: .b, accidental: .sharp, octave: 4), rhythm: .quarter)]
            return testArray
#else
            return _elementArray
#endif
        }
        set {
            _elementArray = newValue
        }
    }
    
    private var ledgerLines: (above: Int, below: Int) {
        guard self.fitsStaffToBounds else {
            let lines = (above: maxLedgerLines, below: maxLedgerLines)
            self.staffLayer.ledgerLines = lines
            return lines
        }
        
        let lines = elementArray.reduce((above: 0, below: 0)) { (result, element) -> (above: Int, below: Int) in
            var result = result
            let elementLedgerLines = element.requiredLedgerLines(in: self.displayedClef)
            if elementLedgerLines > 0 {
                result.above = result.above >= elementLedgerLines ? result.above : elementLedgerLines
            } else if elementLedgerLines < 0 {
                result.below = result.below <= elementLedgerLines ? result.below : abs(elementLedgerLines)
            }
            return result
        }
        
        self.staffLayer.ledgerLines = lines
        return lines
    }
    
    @IBInspectable public var maxLedgerLines: Int = 0 {
        didSet {
            self.setupLayers()
        }
    }
    
    // ⚠️ laissait "private" → inaccessible. On le rend "internal" (par défaut)
    //   et on expose aussi une version publique en lecture seule juste après.
    var centerlineHeight: CGFloat {
        let ledgerOffset = CGFloat(ledgerLines.above - ledgerLines.below) * self.spaceWidth / 2.0
        return self.bounds.size.height / 2.0 + ledgerOffset
    }
    
    /// Exposé pour les vues SwiftUI annexes qui ont besoin de connaître le Y exact du centre.
    public var staffCenterlineY: CGFloat { centerlineHeight }
    
    /// Épaisseur de trait utilisée par la portée (utile pour dessiner des ledger lines cohérentes)
    public var staffLineThickness: CGFloat { staffLayer.lineWidth }
    
    @IBInspectable public var preferredHorizontalSpacing : CGFloat = 0.0 {
        didSet {
            self.setupLayers()
        }
    }
    
    private var displayedClef : MusicClef = .treble
    
    @IBInspectable public var shouldDrawClef: Bool = true {
        didSet {
            self.setupLayers()
        }
    }
    
    @IBInspectable public var shouldDrawNaturals: Bool = true {
        didSet {
            self.setupLayers()
        }
    }
    
    @IBInspectable public var debug : Bool = false {
        didSet{
            self.setupLayers()
        }
    }
    
    override open var bounds : CGRect {
        didSet {
            self.setupLayers()
        }
    }
    
    var spaceWidth : CGFloat {
        get {
            return self.bounds.size.height / (6.0 + CGFloat(self.ledgerLines.above + self.ledgerLines.below))
        }
    }
    
    public var drawAllAccidentals : Bool = false
    
    public var spacing: SpacingType = .uniformTrailingSpace {
        didSet {
            self.setupLayers()
        }
    }
    
    var staffLayer = MusicStaffViewStaffLayer()
    var elementDisplayLayer = CALayer()
    
    #if os(iOS)
    public var staffColor: ColorType = .secondaryLabel
    public var elementColor: ColorType = .label
    #elseif os(macOS)
    public var staffColor: ColorType = .secondaryLabelColor
    public var elementColor: ColorType = .labelColor
    #endif
    
    public func setupLayers() {
        guard self.bounds != .zero else {
            return
        }
        
        staffLayer.removeFromSuperlayer()
        staffLayer = MusicStaffViewStaffLayer()
        staffLayer.frame = self.bounds
        
        elementDisplayLayer.removeFromSuperlayer()
        elementDisplayLayer = CALayer()
        elementDisplayLayer.frame = self.bounds
        
        var elements = [MusicStaffViewElement]()
        
        for element in elementArray {
            guard !(element is MusicClef && !shouldDrawClef) else {
                continue
            }
            
            for accessory in element.accessoryElements {
                switch accessory.placement {
                case .above, .below, .standalone:
                    fatalError("These are not yet implemented")
                case .leading:
                    if let accessory = accessory as? MusicAccidental {
                        if accessory == .natural && !shouldDrawNaturals {
                            continue
                        }
                    }
                    
                    let finalAccessory = AccessoryElementWithParent(parent: element, accessory: accessory)
                    elements.append(finalAccessory)
                    let shim = MusicStaffViewShim(width: preferredHorizontalSpacing, spaceWidth: spaceWidth)
                    elements.append(shim)
                case .trailing:
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
            
            elements.append(element)
            
            if !(element is MusicStaffViewShim) {
                var flexShim = MusicStaffViewShim(width: 0.0, spaceWidth: spaceWidth)
                flexShim.isFlexible = true
                elements.append(flexShim)
            }
        }
        
        let totalElementWidth = elements.reduce(0.0) { (total, nextElement) -> CGFloat in
            return total + nextElement.layer(in: displayedClef, withSpaceWidth: spaceWidth, color: nil).bounds.size.width
        }
        
        var flexWidth: CGFloat = preferredHorizontalSpacing
        
        func setFlexWidth() {
            let viewWidth = self.bounds.size.width
            let extraWidth = viewWidth - totalElementWidth
            
            let numFlexible = elements.filter { (element) -> Bool in
                guard let shim = element as? MusicStaffViewShim else {
                    return false
                }
                return shim.isFlexible
            }.count
            
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
            if elements.last is MusicStaffViewShim {
                let _ = elements.removeLast()
            }
            setFlexWidth()
        case .uniformLeadingAndTrailingSpace:
            var flexShim = MusicStaffViewShim(width: 0.0, spaceWidth: self.spaceWidth)
            flexShim.isFlexible = true
            elements.insert(flexShim, at: 0)
            setFlexWidth()
        case .uniformTrailingSpace:
            setFlexWidth()
            break;
        }
        
        var elementHorizontalPositions = [CGFloat]()
        var elementLayers = [CALayer]()
        var ledgerLineElementIndices = [Int]()
        
        var currentPosition: CGFloat = 0.0
        
        for element in elements {
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
            currentPosition = (elementLayers.last?.frame.origin.x ?? 0) + (elementLayers.last?.frame.size.width ?? 0)
            if element.requiresLedgerLines(in: self.displayedClef) {
                ledgerLineElementIndices.append(elementHorizontalPositions.count)
            }
            elementHorizontalPositions.append(currentPosition)
            
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
            
            for layer in layers {
                if element.requiresLedgerLines(in: self.displayedClef) {
                    let maskRect = extensionFromCenterLine(for: layer.frame, fullHeight: !(element is MusicNote))
                    staffLayer.unmaskRects.append(maskRect)
                }
            }
        }
        
        for layer in elementLayers {
            self.elementDisplayLayer.addSublayer(layer)
        }
        
        staffLayer.maxLedgerLines = self.maxLedgerLines
        let mask = staffLayer.staffLineMask!
        if debug {
            mask.backgroundColor = ColorType(red: 1.0, green: 0.0, blue: 1.0, alpha: 0.5).cgColor
            staffLayer.backgroundColor = ColorType(red: 1.0, green: 0, blue: 0, alpha: 0.25).cgColor
            staffLayer.addSublayer(mask)
        }
        
        staffLayer.strokeColor = staffColor.cgColor
        staffLayer.mask = mask
        
#if os(iOS)
        self.layer.addSublayer(staffLayer)
        self.layer.addSublayer(elementDisplayLayer)
#elseif os(macOS)
        self.layer?.addSublayer(staffLayer)
        self.layer?.addSublayer(elementDisplayLayer)
#endif
        
        if self.fitsStaffToBounds {
            guard
                let mask = staffLayer.staffLineMask as? CAShapeLayer,
                let bounds = mask.path?.boundingBox,
                bounds.width > 0,
                bounds.height > 0
            else {
                return
            }
            
            let scaleAmt = min(self.bounds.width / bounds.width, self.bounds.height / bounds.height)
            
            let scale = CATransform3DMakeScale(scaleAmt, scaleAmt, 1.0)
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
    
    private func layers(for element: MusicStaffViewElement, atHorizontalPosition xPosition: CGFloat) -> [CALayer] {
        var elementLayers = [CALayer]()
        var layer = element.layer(in: displayedClef, withSpaceWidth: self.spaceWidth, color: self.elementColor)
        
        if debug {
            layer.backgroundColor = ColorType(red: 0.0, green: 1.0, blue: 0, alpha: 0.25).cgColor
        }
        
        if element is MusicStaffViewShim {
            layer = element.layer(in: displayedClef, withSpaceWidth: self.spaceWidth, color: .clear)
        }
        
        if element.direction(in: self.displayedClef) == .down {
            layer.transform = CATransform3DMakeRotation(CGFloat(Double.pi), 0, 0, 1.0)
        }
        
        var elementPosition = layer.position
        elementPosition.x = xPosition
        elementPosition.y += centerlineHeight
        
        elementPosition.x += layer.bounds.width * 0.5
        layer.position = elementPosition
        
        elementLayers.append(layer)
        
        return elementLayers
    }
    
    private func viewOffsetForStaffOffset(_ offset: Int) -> CGFloat {
        let offsetFloat = CGFloat(offset)
        return -self.bounds.size.height / 2.0 + offsetFloat * spaceWidth / 2.0
    }
    
    override open func prepareForInterfaceBuilder() {
        Task {
            await self.setupLayers()
        }
    }
    
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
    open override func layoutSubviews() {
        super.layoutSubviews()
        self.setupLayers()
    }
    #endif
}
