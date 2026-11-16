//
//  VirtualDisplayView.swift
//  Vortex
//
//  SwiftUI host for the CAMetalLayer-backed virtual display surface.
//

import SwiftUI
import UIKit
import Metal
import QuartzCore

struct MetalDisplayView: UIViewRepresentable {
    let loop: FrameLoop

    func makeUIView(context: Context) -> MetalDisplaySurfaceUIView {
        let view = MetalDisplaySurfaceUIView()
        view.loop = loop
        return view
    }

    func updateUIView(_ uiView: MetalDisplaySurfaceUIView, context: Context) {
        uiView.loop = loop
        uiView.refreshAttachment()
    }
}

/// UIView whose backing layer is a CAMetalLayer.
final class MetalDisplaySurfaceUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var loop: FrameLoop? {
        didSet { refreshAttachment() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        metalLayer.isOpaque = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            loop?.detachIfCurrent(layer: metalLayer)
        } else {
            refreshAttachment()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil else { return }
        loop?.updateDrawableSize(bounds.size, scale: contentScaleFactor)
    }

    func refreshAttachment() {
        guard let loop, window != nil, bounds.width >= 1, bounds.height >= 1 else { return }
        loop.attach(layer: metalLayer, in: self)
        loop.updateDrawableSize(bounds.size, scale: contentScaleFactor)
    }
}
