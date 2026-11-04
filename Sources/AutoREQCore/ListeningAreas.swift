import Foundation

/// The size of one listening area in the Complete Measurement mode.
public enum AreaSize: String, Codable, CaseIterable, Sendable {
    case singleSeat = "Single seat", largeArea = "Large area", venue = "Venue"

    /// The number of mic positions that the app suggests for an area of this size.
    public var suggestedPositions: Int {
        switch self {
        case .singleSeat: 3
        case .largeArea: 5
        case .venue: 9
        }
    }

    /// Where to put the mic for the positions of this area.
    public var placement: String {
        switch self {
        case .singleSeat: "Put the mic at ear height at the seat. Move it about 15 cm for each new position."
        case .largeArea: "Spread the positions over the whole seating area. Keep the mic at ear height and 50 cm or more from a wall."
        case .venue: "Spread the positions over the audience area in a grid. Include the front, the centre, the back and the two sides."
        }
    }
}

/// The weight of an extra listening area against the main area. The main area always has the weight 1.0.
public enum AreaWeight: Double, Codable, CaseIterable, Sendable, Identifiable {
    case light = 0.25, balanced = 0.5, strong = 0.75, equalToMain = 1.0
    public var id: Double { rawValue }
    public var label: String {
        switch self {
        case .light: "Light"
        case .balanced: "Balanced"
        case .strong: "Strong"
        case .equalToMain: "Equal to main"
        }
    }
}

/// One listening area of the space plan. The first area is the main area, with the weight 1.0.
public struct ListeningArea: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var size: AreaSize
    public var positions: Int
    public var weight: Double

    public init(name: String, size: AreaSize, positions: Int? = nil, weight: Double = 1) {
        self.name = name
        self.size = size
        self.positions = positions ?? size.suggestedPositions
        self.weight = weight
    }

    /// Averages the measurements of all areas on a power basis.
    ///
    /// The positions of one area share the weight of that area equally. Thus an area with 9 positions
    /// has the same effect as an area with 3 positions and the same weight. The function ignores an area without positions.
    public static func combine(_ areas: [(weight: Double, positions: [Response])]) -> Response? {
        let used = areas.filter { !$0.positions.isEmpty && $0.weight > 0 }
        let items = used.flatMap(\.positions)
        let weights = used.flatMap { a in Array(repeating: a.weight / Double(a.positions.count), count: a.positions.count) }
        return Response.powerAverage(items, weights: weights)
    }
}
