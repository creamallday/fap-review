import Foundation

/// A saved set of screening criteria. Stored only on this Mac.
public struct ReviewProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var criteria: String

    public init(id: UUID = UUID(), name: String, criteria: String) {
        self.id = id
        self.name = name
        self.criteria = criteria
    }

    /// Starting point carried over from the earlier FAP Review web app. Edit it in Settings.
    public static let fapScreening = ReviewProfile(
        id: UUID(uuidString: "6F0C3C1E-5D5B-4C55-9C6A-0F3A2E7B1D01")!,
        name: "FAP Screening",
        criteria: """
        Review this Fleet Acquisition Plan (FAP) memo as an OFAM reviewer at the California Department of General Services, Office of Fleet and Asset Management.

        1. ZEV Mandate – Vehicles requested should be zero-emission (BEV/PHEV) unless a valid exemption is claimed and justified.
        2. Exemptions – Any exemption claimed must be specific and substantiated. Flag exemptions that are asserted without supporting facts.
        3. SAM 4121 / 4126 – Check that utilization and acquisition-justification requirements in the State Administrative Manual are addressed. Flag missing required elements.
        4. Utilization – Current vehicle utilization (mileage, trip logs, pooling options) should be documented and meet thresholds (typically 10,000–12,000 miles per year for passenger vehicles).
        5. Routing rationale – The memo should explain the acquisition method (purchase, lease, interagency transfer) and reference the appropriate OFAM forms.
        6. CARB compliance – Requested vehicles should align with CARB fleet rules that apply to state agencies.

        Also correct grammar, spelling, unclear wording and inconsistent figures. Where information is missing, ask for it in a comment rather than inventing it.
        """
    )
}

/// Reads and writes profiles as JSON in Application Support.
public final class ProfileStore {
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FAP Memo Reviewer", isDirectory: true)
        fileURL = base.appendingPathComponent("profiles.json")
    }

    public func load() -> [ReviewProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let profiles = try? JSONDecoder().decode([ReviewProfile].self, from: data),
              !profiles.isEmpty else {
            return [.fapScreening]
        }
        return profiles
    }

    public func save(_ profiles: [ReviewProfile]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}
