//
//  MetalRenderer.swift
//  Vortex
//
//  Host-side Metal renderer: rasterises the guest test pattern into a guest
//  framebuffer texture, then composites that texture into the drawable.
//

import Foundation
import Metal
import QuartzCore

enum MetalRendererError: LocalizedError {
    case commandQueueUnavailable
    case libraryUnavailable
    case missingShaderFunction(String)
    case pipelineCreationFailed(String)
    case textureCreationFailed

    var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable:
            return "A Metal command queue could not be created."
        case .libraryUnavailable:
            return "The compiled Metal shader library is missing from the app bundle."
        case .missingShaderFunction(let name):
            return "Shader function \(name) is missing from the default library."
        case .pipelineCreationFailed(let message):
            return "A render pipeline could not be created: \(message)"
        case .textureCreationFailed:
            return "The guest framebuffer texture could not be allocated."
        }
    }
}

/// Matches `PatternUniforms` in VirtualDisplay.metal (stride 24).
struct PatternUniforms {
    var resolution: SIMD2<Float>
    var marker: SIMD2<Float>
    var markerRadius: Float
}

/// Matches `PresentUniforms` in VirtualDisplay.metal (stride 16).
struct PresentUniforms {
    var rectOrigin: SIMD2<Float>
    var rectSize: SIMD2<Float>
}

final class MetalRenderer {
    struct Configuration {
        var guestWidth: Int = 1280
        var guestHeight: Int = 832
        var renderScale: Double = 1.0
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let guestTexture: MTLTexture
    /// Raster size of the guest framebuffer after resolution scaling.
    let rasterWidth: Int
    let rasterHeight: Int
    /// Guest logical size, independent of the raster scale.
    let guestWidth: Int
    let guestHeight: Int
    let renderScale: Double

    private let patternPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let samplerState: MTLSamplerState

    init(device: MTLDevice, configuration: Configuration = Configuration()) throws {
        guard let queue = device.makeCommandQueue() else {
            throw MetalRendererError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw MetalRendererError.libraryUnavailable
        }

        let scale = min(max(configuration.renderScale, 0.25), 4.0)
        let rasterWidth = max(16, Int((Double(configuration.guestWidth) * scale).rounded()))
        let rasterHeight = max(16, Int((Double(configuration.guestHeight) * scale).rounded()))

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                         width: rasterWidth,
                                                                         height: rasterHeight,
                                                                         mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw MetalRendererError.textureCreationFailed
        }

        guard let patternVertex = library.makeFunction(name: "pattern_vertex") else {
            throw MetalRendererError.missingShaderFunction("pattern_vertex")
        }
        guard let patternFragment = library.makeFunction(name: "pattern_fragment") else {
            throw MetalRendererError.missingShaderFunction("pattern_fragment")
        }
        guard let presentVertex = library.makeFunction(name: "present_vertex") else {
            throw MetalRendererError.missingShaderFunction("present_vertex")
        }
        guard let presentFragment = library.makeFunction(name: "present_fragment") else {
            throw MetalRendererError.missingShaderFunction("present_fragment")
        }

        let patternDescriptor = MTLRenderPipelineDescriptor()
        patternDescriptor.label = "Vortex test pattern"
        patternDescriptor.vertexFunction = patternVertex
        patternDescriptor.fragmentFunction = patternFragment
        patternDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let presentDescriptor = MTLRenderPipelineDescriptor()
        presentDescriptor.label = "Vortex present blit"
        presentDescriptor.vertexFunction = presentVertex
        presentDescriptor.fragmentFunction = presentFragment
        presentDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.patternPipeline = try device.makeRenderPipelineState(descriptor: patternDescriptor)
            self.presentPipeline = try device.makeRenderPipelineState(descriptor: presentDescriptor)
        } catch {
            throw MetalRendererError.pipelineCreationFailed(error.localizedDescription)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalRendererError.pipelineCreationFailed("sampler state")
        }

        self.device = device
        self.commandQueue = queue
        self.guestTexture = texture
        self.rasterWidth = rasterWidth
        self.rasterHeight = rasterHeight
        self.guestWidth = configuration.guestWidth
        self.guestHeight = configuration.guestHeight
        self.renderScale = scale
        self.samplerState = sampler
    }

    /// Encodes one full frame. The caller presents and commits the buffer so it
    /// can attach its own completion handler and measure GPU time.
    func encodeFrame(drawable: CAMetalDrawable,
                     drawableSize: CGSize,
                     markerPosition: Float) -> MTLCommandBuffer? {
        guard drawableSize.width >= 1, drawableSize.height >= 1 else { return nil }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        let patternPass = MTLRenderPassDescriptor()
        patternPass.colorAttachments[0].texture = guestTexture
        patternPass.colorAttachments[0].loadAction = .clear
        patternPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        patternPass.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: patternPass) {
            encoder.label = "Guest raster"
            encoder.setRenderPipelineState(patternPipeline)
            var uniforms = PatternUniforms(
                resolution: SIMD2<Float>(Float(rasterWidth), Float(rasterHeight)),
                marker: SIMD2<Float>(markerPosition * Float(rasterWidth), Float(rasterHeight) * 0.5),
                markerRadius: Float(rasterWidth) * 0.058
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PatternUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        let presentPass = MTLRenderPassDescriptor()
        presentPass.colorAttachments[0].texture = drawable.texture
        presentPass.colorAttachments[0].loadAction = .clear
        presentPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        presentPass.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: presentPass) {
            encoder.label = "Present"
            encoder.setRenderPipelineState(presentPipeline)
            let rect = aspectFitRect(in: drawableSize)
            var uniforms = PresentUniforms(
                rectOrigin: SIMD2<Float>(Float(rect.origin.x), Float(rect.origin.y)),
                rectSize: SIMD2<Float>(Float(rect.width), Float(rect.height))
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PresentUniforms>.stride, index: 0)
            encoder.setFragmentTexture(guestTexture, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        return commandBuffer
    }

    /// Aspect-fit rect for the guest raster inside the drawable, in pixels.
    func aspectFitRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let rasterAspect = CGFloat(rasterWidth) / CGFloat(rasterHeight)
        let viewAspect = size.width / size.height

        var width = size.width
        var height = size.height
        if viewAspect > rasterAspect {
            width = height * rasterAspect
        } else {
            height = width / rasterAspect
        }

        return CGRect(x: (size.width - width) / 2,
                      y: (size.height - height) / 2,
                      width: width,
                      height: height)
    }
}
