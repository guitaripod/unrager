import UIKit
import MetalKit
import simd

/// A full-screen, Metal-rendered loading state for the rage-filter's
/// "collecting tweets" phase. A field of soft accent-blue metaballs drifts over
/// the app background and *condenses* toward center as progress climbs from
/// 0 to 1, ringed by a pulse whose radius tracks the same value — so the
/// animation visibly reflects the batch filling. The live "collecting tweets…
/// N/25" caption overlays the lower third in `DesignSystem` typography.
/// In light mode the accent mix is capped low so overlapping orbs stay
/// discrete soft shapes on white instead of flooding the frame flat blue.
///
/// Driven by `MTKView`'s own `CADisplayLink` at ~60fps; paused whenever the
/// view is hidden or off-window so it draws zero frames in the background.
/// When `MTLCreateSystemDefaultDevice()` returns nil (CI, some simulators),
/// `isAvailable` is false and the caller falls back to the spinner + label.
final class MetalCollectingView: UIView {
    /// False when no Metal device exists (CI / headless sim). The caller keeps
    /// the legacy spinner + label path alive for this case.
    let isAvailable: Bool

    private var metalView: MTKView?
    private var renderer: CollectingRenderer?
    private let caption = UILabel()
    private let titleLabel = UILabel()

    /// Latched progress 0…1 (N / targetSurvivors), driven into the shader.
    private var progress: Float = 0

    override init(frame: CGRect) {
        if let device = MTLCreateSystemDefaultDevice() {
            isAvailable = true
            let view = MTKView(frame: frame, device: device)
            metalView = view
            super.init(frame: frame)
            configureMetal(view, device: device)
        } else {
            isAvailable = false
            super.init(frame: frame)
        }
        configureCaption()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalCollectingView, _) in
            view.syncAppearance()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureMetal(_ view: MTKView, device: any MTLDevice) {
        view.backgroundColor = .clear
        view.isOpaque = false
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        renderer = CollectingRenderer(device: device, pixelFormat: view.colorPixelFormat)
        view.delegate = renderer
        addManaged(view)
        view.pinEdges(to: self)
    }

    private func configureCaption() {
        titleLabel.font = DesignSystem.Typography.title()
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.textAlignment = .center
        titleLabel.text = "Collecting your feed"
        titleLabel.adjustsFontForContentSizeCategory = true

        caption.font = DesignSystem.Typography.metric()
        caption.textColor = DesignSystem.Color.secondaryLabel
        caption.textAlignment = .center
        caption.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, caption])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = DesignSystem.Spacing.xs
        addManaged(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor,
                                          constant: -DesignSystem.Spacing.xxl * 2),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DesignSystem.Spacing.xl),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignSystem.Spacing.xl),
        ])
    }

    /// Pushes the collected count toward the target, animating the latched
    /// progress so the field condenses smoothly rather than snapping per keep.
    func update(collected: Int, target: Int) {
        let denom = max(1, target)
        progress = min(1, Float(collected) / Float(denom))
        renderer?.targetProgress = progress
        caption.text = "collecting tweets… \(collected)/\(denom)"
    }

    /// Starts the display link only when actually on screen.
    func start() {
        guard isAvailable else { return }
        syncAppearance()
        metalView?.isPaused = false
    }

    /// Stops drawing entirely — no frames, no battery — when hidden or removed.
    func stop() {
        metalView?.isPaused = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() }
    }

    private func syncAppearance() {
        renderer?.setPalette(
            accent: DesignSystem.Color.accent.resolvedColor(with: traitCollection),
            background: DesignSystem.Color.background.resolvedColor(with: traitCollection),
            isDark: traitCollection.userInterfaceStyle == .dark)
    }
}

/// The `MTKViewDelegate` that owns the pipeline and drives the fullscreen
/// metaball shader. The shader source is compiled at runtime via
/// `makeLibrary(source:)` so no `.metal` file (and thus no project.yml change)
/// is needed.
private final class CollectingRenderer: NSObject, MTKViewDelegate {
    /// The progress the field eases toward; latched smoothly each frame.
    var targetProgress: Float = 0

    private let commandQueue: any MTLCommandQueue
    private var pipeline: (any MTLRenderPipelineState)?
    private var startTime = CFAbsoluteTimeGetCurrent()
    private var easedProgress: Float = 0
    private var uniforms = CollectingUniforms()

    init?(device: any MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue
        super.init()
        buildPipeline(device: device, pixelFormat: pixelFormat)
    }

    func setPalette(accent: UIColor, background: UIColor, isDark: Bool) {
        uniforms.accent = accent.simd3
        uniforms.background = background.simd3
        uniforms.isDark = isDark ? 1 : 0
    }

    private func buildPipeline(device: any MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: CollectingShader.source, options: nil) else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "collecting_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "collecting_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        easedProgress += (targetProgress - easedProgress) * 0.08
        uniforms.time = Float(CFAbsoluteTimeGetCurrent() - startTime)
        uniforms.progress = easedProgress
        uniforms.resolution = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CollectingUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// CPU mirror of the shader's uniform block. Field order and padding match the
/// Metal `struct Uniforms`.
private struct CollectingUniforms {
    var resolution = SIMD2<Float>(1, 1)
    var time: Float = 0
    var progress: Float = 0
    var accent = SIMD3<Float>(0.2, 0.6, 0.95)
    var isDark: Float = 1
    var background = SIMD3<Float>(0, 0, 0)
    var pad: Float = 0
}

private extension UIColor {
    var simd3: SIMD3<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3<Float>(Float(r), Float(g), Float(b))
    }
}

/// The fullscreen metaball / condensing-field fragment shader, shared verbatim
/// with the macOS client (same source string).
enum CollectingShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float time;
        float progress;
        float3 accent;
        float isDark;
        float3 background;
        float pad;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut collecting_vertex(uint vid [[vertex_id]]) {
        float2 pts[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        VOut out;
        out.position = float4(pts[vid], 0.0, 1.0);
        out.uv = pts[vid] * 0.5 + 0.5;
        return out;
    }

    static float hash(float n) { return fract(sin(n) * 43758.5453123); }

    // Six drifting orbs that orbit the center and pull inward as progress climbs.
    fragment float4 collecting_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 res = u.resolution;
        float2 frag = in.uv * res;
        float aspect = res.x / max(res.y, 1.0);
        float2 p = (frag / res - 0.5);
        p.x *= aspect;

        float t = u.time;
        float prog = clamp(u.progress, 0.0, 1.0);

        // Field of metaballs. Each orbits at its own radius/phase; the orbit
        // radius collapses toward center as progress fills.
        float field = 0.0;
        const int COUNT = 6;
        for (int i = 0; i < COUNT; i++) {
            float fi = float(i);
            float seed = hash(fi * 12.13);
            float spread = mix(0.46, 0.07, prog) * (0.6 + seed * 0.7);
            float speed = 0.18 + seed * 0.5;
            float phase = seed * 6.2831 + t * speed * (i % 2 == 0 ? 1.0 : -1.0);
            float wobble = 0.05 * sin(t * (0.7 + seed) + fi);
            float2 c = float2(cos(phase), sin(phase * 1.3 + seed)) * (spread + wobble);
            float r = mix(0.16, 0.30, hash(fi * 3.7));
            float d = length(p - c);
            field += (r * r) / (d * d + 0.0008);
        }

        // Central well that intensifies as the batch coalesces.
        float core = length(p);
        field += mix(0.05, 0.7, prog) * (0.09 / (core * core + 0.01));

        float mass = smoothstep(0.8, 2.6, field);

        // Concentric pulse ring whose radius tracks progress.
        float ringR = mix(0.12, 0.62, prog);
        float pulse = 0.5 + 0.5 * sin(t * 2.2);
        float ringW = mix(0.012, 0.03, pulse);
        float ring = smoothstep(ringW, 0.0, abs(core - ringR)) * (0.25 + 0.35 * pulse) * (0.4 + 0.6 * prog);

        // Soft vignette for depth.
        float vignette = 1.0 - smoothstep(0.55, 1.15, core);

        float3 accent = u.accent;
        float3 hot = mix(accent, float3(1.0), 0.35);
        float3 glow = mix(accent, hot, mass);

        float intensity = (mass * (0.55 + 0.45 * prog) + ring) * vignette;
        // Brighten the whole field as it nears completion.
        intensity *= mix(0.7, 1.25, prog);

        float3 bg = u.background;
        float3 color;
        if (u.isDark > 0.5) {
            color = bg + glow * intensity;
        } else {
            float3 tinted = mix(bg, accent, 0.05);
            color = mix(tinted, accent, clamp(intensity, 0.0, 1.0) * 0.32);
        }

        // Fine grain to avoid banding on the gradients.
        float grain = (hash(dot(frag, float2(12.9898, 78.233)) + t) - 0.5) * 0.012;
        color += grain;

        return float4(clamp(color, 0.0, 1.0), 1.0);
    }
    """
}
