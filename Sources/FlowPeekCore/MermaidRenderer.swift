import CoreGraphics
import Foundation

/// Bounds applied in Swift before a source ever reaches JavaScript, plus the ceilings handed to
/// mermaid itself. The engine ceilings sit deliberately above the Swift gates so mermaid's silent
/// `Maximum text size in diagram exceeded` substitution is unreachable.
public enum MermaidRenderLimits {
    /// Compared in UTF-16 code units — the same unit mermaid's `maxTextSize` counts.
    public static let maximumSourceUTF16 = 100_000
    public static let maximumLines = 5_000
    public static let maximumLineLength = 20_000
    public static let engineMaximumTextSize = 120_000
    public static let engineMaximumEdges = 2_000
    public static let timeoutSeconds = 8

    public static func validate(_ source: String) throws(MermaidRenderError) {
        let utf16 = source.utf16.count
        guard utf16 <= maximumSourceUTF16 else {
            throw .inputTooLarge(utf16: utf16, limit: maximumSourceUTF16)
        }
        var lines = 1
        var current = 0
        var longest = 0
        for unit in source.utf16 {
            if unit == 0x0A {
                lines += 1
                longest = max(longest, current)
                current = 0
            } else {
                current += 1
            }
        }
        longest = max(longest, current)
        guard lines <= maximumLines else { throw .inputTooLarge(utf16: lines, limit: maximumLines) }
        guard longest <= maximumLineLength else { throw .inputTooLarge(utf16: longest, limit: maximumLineLength) }
    }
}

public struct MermaidRenderRequest: Sendable, Equatable {
    public let source: String
    public let theme: MacMermaidTheme
    public let seed: String
    public let renderID: String

    public init(source: String, theme: MacMermaidTheme, seed: String, renderID: String) {
        self.source = source
        self.theme = theme
        self.seed = seed
        self.renderID = renderID
    }

    /// The JSON string handed to `window.__flowpeek.render`.
    public func payloadJSON() throws(MermaidRenderError) -> String {
        try MermaidRenderLimits.validate(source)
        let payload = MermaidRenderPayload(
            source: source,
            renderID: renderID,
            seed: seed,
            fontFamily: theme.fontFamily,
            themeVariables: theme.variables,
            themeCSS: theme.css
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            guard let json = String(data: try encoder.encode(payload), encoding: .utf8) else {
                throw MermaidRenderError.internalFailure("render payload is not valid UTF-8")
            }
            return json
        } catch let error as MermaidRenderError {
            throw error
        } catch {
            throw .internalFailure(String(describing: error))
        }
    }
}

/// Render ids double as raw CSS selectors inside mermaid, so they must never start with a digit.
public enum MermaidRenderIdentifier {
    public static func renderID(_ counter: UInt64) -> String { "fp-\(counter)" }

    public static func seed(for document: UUID) -> String { "fp-" + document.uuidString.lowercased() }
}

struct MermaidRenderPayload: Codable, Equatable, Sendable {
    let source: String
    let renderID: String
    let seed: String
    let fontFamily: String
    let themeVariables: [String: String]
    let themeCSS: String
}

public struct MermaidRenderResult: Sendable, Equatable {
    public let svg: String
    public let diagramType: String
    public let width: Double
    public let height: Double
    public let scrubbed: [String]
    public let durationMS: Int
    public let cspViolations: [String]

    public init(
        svg: String,
        diagramType: String,
        width: Double,
        height: Double,
        scrubbed: [String],
        durationMS: Int,
        cspViolations: [String] = []
    ) {
        self.svg = svg
        self.diagramType = diagramType
        self.width = width
        self.height = height
        self.scrubbed = scrubbed
        self.durationMS = durationMS
        self.cspViolations = cspViolations
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    /// Scale that fits the diagram into `viewport`, clamped to `DiagramViewport`'s own range.
    public func fitScale(in viewport: CGSize, inset: CGFloat = 36) -> Double {
        guard width > 0, height > 0 else { return 1 }
        let available = CGSize(width: viewport.width - 2 * inset, height: viewport.height - 2 * inset)
        guard available.width > 0, available.height > 0 else { return 0.2 }
        let scale = min(1, min(available.width / width, available.height / height))
        return min(max(Double(scale), 0.2), 5)
    }
}

public enum MermaidRenderError: Error, LocalizedError, Equatable, Sendable {
    case engineMissing
    case engineNotReady
    case webContentTerminated
    case navigationFailed(String)
    case inputTooLarge(utf16: Int, limit: Int)
    case unknownDiagramType(String)
    case parseFailure(message: String, line: Int?)
    case edgeLimitExceeded(message: String)
    case renderProducedNoSVG
    case timedOut(seconds: Int)
    case internalFailure(String)

    /// WebKit's placeholder text for every JS fault; it must never reach the user.
    public static let genericJavaScriptExceptionMessage = "A JavaScript exception occurred"

    /// Prefers `WKJavaScriptExceptionMessage` over `localizedDescription`, which is always the
    /// useless generic string above.
    public static func javaScriptException(_ error: some Error) -> MermaidRenderError {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String, !message.isEmpty {
            return .internalFailure(message)
        }
        if let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
           !message.isEmpty, message != genericJavaScriptExceptionMessage {
            return .internalFailure(message)
        }
        return .internalFailure("\(nsError.domain) \(nsError.code)")
    }

    public var localizationKey: String {
        switch self {
        case .engineMissing: "mermaid.render.error.engine-missing"
        case .engineNotReady: "mermaid.render.error.engine-not-ready"
        case .webContentTerminated: "mermaid.render.error.web-content-terminated"
        case .navigationFailed: "mermaid.render.error.navigation-failed"
        case .inputTooLarge: "mermaid.render.error.input-too-large"
        case .unknownDiagramType: "mermaid.render.error.unknown-type"
        case .parseFailure(_, let line): line == nil ? "mermaid.render.error.parse" : "mermaid.render.error.parse-line"
        case .edgeLimitExceeded: "mermaid.render.error.edge-limit"
        case .renderProducedNoSVG: "mermaid.render.error.no-svg"
        case .timedOut: "mermaid.render.error.timed-out"
        case .internalFailure: "mermaid.render.error.internal"
        }
    }

    /// Every key this type can emit — the localisation test walks it.
    public static let localizationKeys = [
        "mermaid.render.error.engine-missing",
        "mermaid.render.error.engine-not-ready",
        "mermaid.render.error.web-content-terminated",
        "mermaid.render.error.navigation-failed",
        "mermaid.render.error.input-too-large",
        "mermaid.render.error.unknown-type",
        "mermaid.render.error.parse",
        "mermaid.render.error.parse-line",
        "mermaid.render.error.edge-limit",
        "mermaid.render.error.no-svg",
        "mermaid.render.error.timed-out",
        "mermaid.render.error.internal",
    ]

    public var errorDescription: String? {
        let template = String(localized: String.LocalizationValue(localizationKey))
        switch self {
        case .engineMissing, .engineNotReady, .webContentTerminated, .renderProducedNoSVG:
            return template
        case .navigationFailed(let detail), .unknownDiagramType(let detail),
             .edgeLimitExceeded(let detail), .internalFailure(let detail):
            return String(format: template, detail)
        case .inputTooLarge(let utf16, let limit):
            return String(format: template, utf16, limit)
        case .parseFailure(let message, let line):
            if let line { return String(format: template, line, message) }
            return String(format: template, message)
        case .timedOut(let seconds):
            return String(format: template, seconds)
        }
    }
}

// MARK: - The JSON contract the glue speaks

/// Failure codes emitted by `flowpeek-glue.js`.
public enum MermaidGlueCode: String, Codable, Sendable, CaseIterable {
    case engineMissing = "engine-missing"
    case engineNotReady = "engine-not-ready"
    case renderProducedNoSVG = "render-no-svg"
    case tooLarge = "too-large"
    case edgeLimit = "edge-limit"
    case unknownType = "unknown-type"
    case parse
    case internalFailure = "internal"
}

public struct MermaidGlueResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var code: String?
    public var message: String?
    public var line: Int?
    public var diagramType: String?
    public var width: Double?
    public var height: Double?
    public var scrubbed: [String]?
    public var svg: String?
    public var durationMS: Int?
    public var engineVersion: String?
    public var cspViolations: [String]?

    public init(
        ok: Bool,
        code: String? = nil,
        message: String? = nil,
        line: Int? = nil,
        diagramType: String? = nil,
        width: Double? = nil,
        height: Double? = nil,
        scrubbed: [String]? = nil,
        svg: String? = nil,
        durationMS: Int? = nil,
        engineVersion: String? = nil,
        cspViolations: [String]? = nil
    ) {
        self.ok = ok
        self.code = code
        self.message = message
        self.line = line
        self.diagramType = diagramType
        self.width = width
        self.height = height
        self.scrubbed = scrubbed
        self.svg = svg
        self.durationMS = durationMS
        self.engineVersion = engineVersion
        self.cspViolations = cspViolations
    }
}

public struct MermaidGlueHealthResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var code: String?
    public var message: String?
    public var diagramType: String?
    public var width: Double?
    public var height: Double?
    public var scrubbed: [String]?
    public var cspViolations: [String]?
    public var engineVersion: String?
    public var canaryMS: Int?
}

/// Decodes the glue's JSON into the typed Swift surface. Pure, so the mapping is unit-testable
/// without a WebView.
public enum MermaidGlueDecoder {
    public static let canarySource = "flowchart TD\n  A[Start] --> B[End]"
    public static let canaryDiagramType = "flowchart-v2"
    public static let sizeLimitPlaceholder = "Maximum text size in diagram exceeded"

    public static func result(
        from json: String,
        sourceUTF16Count: Int
    ) throws(MermaidRenderError) -> MermaidRenderResult {
        let response: MermaidGlueResponse
        do {
            response = try JSONDecoder().decode(MermaidGlueResponse.self, from: Data(json.utf8))
        } catch {
            throw .internalFailure("the render glue returned undecodable JSON: \(json.prefix(200))")
        }
        return try result(from: response, sourceUTF16Count: sourceUTF16Count)
    }

    public static func result(
        from response: MermaidGlueResponse,
        sourceUTF16Count: Int
    ) throws(MermaidRenderError) -> MermaidRenderResult {
        guard response.ok else { throw error(from: response, sourceUTF16Count: sourceUTF16Count) }
        guard let svg = response.svg, let width = response.width, let height = response.height,
              width > 0, height > 0 else {
            throw .renderProducedNoSVG
        }
        return MermaidRenderResult(
            svg: svg,
            diagramType: response.diagramType ?? "",
            width: width,
            height: height,
            scrubbed: response.scrubbed ?? [],
            durationMS: response.durationMS ?? 0,
            cspViolations: response.cspViolations ?? []
        )
    }

    public static func error(from response: MermaidGlueResponse, sourceUTF16Count: Int) -> MermaidRenderError {
        let message = response.message ?? ""
        switch MermaidGlueCode(rawValue: response.code ?? "") {
        case .engineMissing: return .engineMissing
        case .engineNotReady: return .engineNotReady
        case .renderProducedNoSVG: return .renderProducedNoSVG
        case .tooLarge:
            return .inputTooLarge(utf16: sourceUTF16Count, limit: MermaidRenderLimits.maximumSourceUTF16)
        case .edgeLimit: return .edgeLimitExceeded(message: message)
        case .unknownType: return .unknownDiagramType(message)
        case .parse: return .parseFailure(message: message, line: response.line)
        case .internalFailure: return .internalFailure(message)
        case nil:
            return .internalFailure("unrecognised render glue code \"\(response.code ?? "nil")\": \(message)")
        }
    }

    public static func health(from json: String, warmupMS: Int) -> MermaidEngineHealth {
        let response: MermaidGlueHealthResponse
        do {
            response = try JSONDecoder().decode(MermaidGlueHealthResponse.self, from: Data(json.utf8))
        } catch {
            return MermaidEngineHealth(
                status: .broken(.internalFailure("the self-test returned undecodable JSON: \(json.prefix(200))")),
                engineVersion: nil,
                warmupMS: warmupMS,
                canaryMS: 0
            )
        }
        return health(from: response, warmupMS: warmupMS)
    }

    public static func health(from response: MermaidGlueHealthResponse, warmupMS: Int) -> MermaidEngineHealth {
        let canaryMS = response.canaryMS ?? 0
        guard response.ok else {
            let failure = error(
                from: MermaidGlueResponse(ok: false, code: response.code, message: response.message),
                sourceUTF16Count: canarySource.utf16.count
            )
            return MermaidEngineHealth(status: .broken(failure), engineVersion: response.engineVersion, warmupMS: warmupMS, canaryMS: canaryMS)
        }
        guard (response.width ?? 0) > 0, (response.height ?? 0) > 0 else {
            return MermaidEngineHealth(status: .broken(.renderProducedNoSVG), engineVersion: response.engineVersion, warmupMS: warmupMS, canaryMS: canaryMS)
        }
        var complaints: [String] = []
        if response.diagramType != canaryDiagramType {
            complaints.append("canary detected as \(response.diagramType ?? "nothing"), expected \(canaryDiagramType)")
        }
        if let scrubbed = response.scrubbed, !scrubbed.isEmpty {
            complaints.append("canary needed scrubbing: \(scrubbed.joined(separator: ","))")
        }
        if let violations = response.cspViolations, !violations.isEmpty {
            complaints.append("content-security-policy violations: \(violations.joined(separator: ","))")
        }
        return MermaidEngineHealth(
            status: complaints.isEmpty ? .healthy : .degraded(complaints.joined(separator: "; ")),
            engineVersion: response.engineVersion,
            warmupMS: warmupMS,
            canaryMS: canaryMS
        )
    }
}

public struct MermaidEngineHealth: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case healthy
        case degraded(String)
        case broken(MermaidRenderError)
    }

    public let status: Status
    public let engineVersion: String?
    public let warmupMS: Int
    public let canaryMS: Int

    public init(status: Status, engineVersion: String?, warmupMS: Int, canaryMS: Int) {
        self.status = status
        self.engineVersion = engineVersion
        self.warmupMS = warmupMS
        self.canaryMS = canaryMS
    }

    public var isUsable: Bool {
        switch status {
        case .healthy, .degraded: true
        case .broken: false
        }
    }

    /// The single line the menu bar shows when the engine cannot be trusted.
    public var menuDescription: String? {
        switch status {
        case .healthy:
            return nil
        case .degraded(let detail):
            return String(format: String(localized: "mermaid.engine.degraded"), detail)
        case .broken(let error):
            return String(format: String(localized: "mermaid.engine.broken"), error.localizedDescription)
        }
    }
}

@MainActor
public protocol MermaidRendering: AnyObject {
    func render(_ request: MermaidRenderRequest) async throws(MermaidRenderError) -> MermaidRenderResult
    func selfTest() async -> MermaidEngineHealth
}
